using System.Diagnostics;
using Microsoft.UI.Dispatching;
using SpatialBridge.App.Services;
using SpatialBridge.Core;
using SpatialBridge.Platform.Windows.Display;

namespace SpatialBridge.App.Overlay;

/// <summary>
/// Places and animates the arrival card (port of the Mac's <c>ArrivalOverlayController</c>).
/// It starts on <see cref="ReceiverEvent.TransferIncoming"/>; everything before <see cref="ShowSaved"/>
/// (called only on <see cref="ReceiverEvent.TransferCommitted"/>) is provisional (AGENTS.md, AD §4).
/// Honours Windows "Animation effects" (SPI_GETCLIENTAREAANIMATION) like Reduce Motion on the Mac.
/// Must be used on the UI thread.
/// </summary>
internal sealed class ArrivalOverlayController : IDisposable
{
    private const double RestInsetDips = 24;
    private const double PaddingDips = 24;
    private const double ReducedMotionFadeSeconds = 0.2;
    private const double FadeOutSeconds = 0.25;

    private readonly LayeredOverlayWindow _window = new();
    private readonly DispatcherQueueTimer _timer;
    private readonly Stopwatch _clock = Stopwatch.StartNew();

    private Guid? _current;
    private ArrivalPhase _phase = new ArrivalPhase.Incoming(0);
    private string _subtitle = string.Empty;
    private RectD _windowFrame;
    private double _scale = 1;
    private double _entryX, _entryY, _restX, _restY;
    private SpringCurve _spring = SpringCurve.ForIntensity(0.5);
    private bool _reduceMotion;
    private double _shownAt;
    private double _phaseChangedAt;
    private double? _hideAt;
    private double? _fadeOutStartedAt;

    public ArrivalOverlayController(DispatcherQueue dispatcher)
    {
        _timer = dispatcher.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(16);
        _timer.IsRepeating = true;
        _timer.Tick += (_, _) => Tick();
    }

    public static IReadOnlyList<MonitorGeometry> Displays() => MonitorEnumerator.GetMonitors();

    /// <summary>Starts the provisional arrival. Returns false if no display or window is available (caller falls back to a notification).</summary>
    public bool ShowIncoming(Guid transferID, string subtitle, ExitGesture? gesture, string? displayId)
    {
        var started = _clock.Elapsed.TotalSeconds;
        var monitor = ArrivalLayout.SelectMonitor(displayId, Displays());
        if (monitor is null || !_window.EnsureCreated())
        {
            DiagnosticsLog.Shared.Write("overlay.unavailable");
            return false;
        }

        var exit = gesture ?? ArrivalLayout.DefaultGesture;
        _scale = monitor.Scale;
        var cardWidth = ArrivalCardRenderer.CardWidth * _scale;
        var cardHeight = ArrivalCardRenderer.CardHeight * _scale;
        var placement = ArrivalLayout.Place(exit, monitor, cardWidth, cardHeight, RestInsetDips * _scale);
        _windowFrame = ArrivalLayout.OverlayFrame(placement, monitor, PaddingDips * _scale);
        if (_windowFrame.IsEmpty || !_window.EnsureSurface((int)Math.Ceiling(_windowFrame.Width), (int)Math.Ceiling(_windowFrame.Height)))
        {
            return false;
        }

        _current = transferID;
        _subtitle = subtitle;
        _phase = new ArrivalPhase.Incoming(0);
        _reduceMotion = !AnimationSettings.ClientAreaAnimationsEnabled();
        _spring = SpringCurve.ForIntensity(ArrivalLayout.Intensity(exit));
        _entryX = placement.EntryX - _windowFrame.X;
        _entryY = placement.EntryY - _windowFrame.Y;
        _restX = placement.CardFrame.CenterX - _windowFrame.X;
        _restY = placement.CardFrame.CenterY - _windowFrame.Y;
        _shownAt = _phaseChangedAt = _clock.Elapsed.TotalSeconds;
        _hideAt = null;
        _fadeOutStartedAt = null;

        Draw();
        _timer.Start();
        DiagnosticsLog.Shared.Write($"overlay.start edge={placement.Edge} latencyMs={(int)((_clock.Elapsed.TotalSeconds - started) * 1000)} reduceMotion={_reduceMotion}");
        return true;
    }

    public void ShowProgress(Guid transferID, double fraction)
    {
        if (transferID != _current || _phase is ArrivalPhase.Saved or ArrivalPhase.Failed)
        {
            return;
        }
        SetPhase(fraction >= 1 ? new ArrivalPhase.Verifying() : new ArrivalPhase.Incoming(fraction), resetClock: false);
    }

    /// <summary>Final success, only after durable save and COMMITTED (FR-209).</summary>
    public void ShowSaved(Guid transferID, string savedName)
    {
        if (transferID != _current)
        {
            return;
        }
        SetPhase(new ArrivalPhase.Saved(savedName), resetClock: true);
        ScheduleHide(2.2);
    }

    public void ShowFailed(Guid transferID, BridgeErrorCode code)
    {
        if (transferID != _current)
        {
            return;
        }
        SetPhase(new ArrivalPhase.Failed(code), resetClock: true);
        ScheduleHide(3);
    }

    /// <summary>Settings › Overlay › Test Arrival: a scripted local preview; nothing is received.</summary>
    public async Task TestAsync(string? displayId, Edge exitEdge)
    {
        var id = Guid.NewGuid();
        if (!ShowIncoming(id, "Test Photo.jpeg", new ExitGesture(exitEdge, 0.5, 900, 0, 0), displayId))
        {
            return;
        }
        for (var step = 1; step <= 5; step++)
        {
            await Task.Delay(120).ConfigureAwait(true);
            ShowProgress(id, step / 5.0 * 0.99);
        }
        ShowSaved(id, "Test Photo.jpeg");
    }

    public void Dispose()
    {
        _timer.Stop();
        _window.Dispose();
    }

    private void SetPhase(ArrivalPhase phase, bool resetClock)
    {
        _phase = phase;
        if (resetClock)
        {
            _phaseChangedAt = _clock.Elapsed.TotalSeconds;
        }
        Draw();
        _timer.Start();
    }

    private void ScheduleHide(double afterSeconds)
    {
        _hideAt = _clock.Elapsed.TotalSeconds + afterSeconds;
        _timer.Start();
    }

    private void Tick()
    {
        if (_current is null)
        {
            _timer.Stop();
            return;
        }
        var now = _clock.Elapsed.TotalSeconds;
        if (_hideAt is { } hideAt && now >= hideAt && _fadeOutStartedAt is null)
        {
            _fadeOutStartedAt = now;
        }
        if (_fadeOutStartedAt is { } fadeStart && now - fadeStart >= FadeOutSeconds)
        {
            _window.Hide();
            _current = null;
            _timer.Stop();
            return;
        }
        Draw();

        // Idle until the next scheduled change once entry and the status pop have settled.
        var entrySettled = now - _shownAt > (_reduceMotion ? ReducedMotionFadeSeconds : _spring.SettleTime());
        var popSettled = now - _phaseChangedAt > SpringCurve.Settle.SettleTime();
        if (entrySettled && popSettled && _hideAt is null)
        {
            _timer.Stop();
        }
    }

    private void Draw()
    {
        var now = _clock.Elapsed.TotalSeconds;
        var t = now - _shownAt;
        double progress, opacity, cardScale;
        if (_reduceMotion)
        {
            progress = 1;
            cardScale = 1;
            var f = Math.Clamp(t / ReducedMotionFadeSeconds, 0, 1);
            opacity = 1 - ((1 - f) * (1 - f)); // ease-out
        }
        else
        {
            progress = _spring.Value(t);
            cardScale = 0.7 + (0.3 * progress);
            opacity = Math.Clamp(progress, 0, 1);
        }
        if (_fadeOutStartedAt is { } fadeStart)
        {
            var f = Math.Clamp((now - fadeStart) / FadeOutSeconds, 0, 1);
            opacity *= 1 - (f * f); // ease-in
        }

        var iconScale = _phase is ArrivalPhase.Saved
            ? (_reduceMotion ? 1 : SpringCurve.Settle.Value(now - _phaseChangedAt))
            : 1;

        var frame = new CardFrame(
            _phase,
            _subtitle,
            _entryX + ((_restX - _entryX) * progress),
            _entryY + ((_restY - _entryY) * progress),
            cardScale,
            iconScale,
            _scale);
        ArrivalCardRenderer.Render(_window.Bits, _window.Width, _window.Height, frame);
        _window.Present((int)Math.Round(_windowFrame.X), (int)Math.Round(_windowFrame.Y), (byte)Math.Round(Math.Clamp(opacity, 0, 1) * 255));
    }
}
