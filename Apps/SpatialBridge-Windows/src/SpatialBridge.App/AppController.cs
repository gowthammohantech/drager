using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using SpatialBridge.App.Fakes;
using SpatialBridge.App.Overlay;
using SpatialBridge.App.Services;
using SpatialBridge.App.Tray;
using SpatialBridge.App.Windows;
using SpatialBridge.Core;

namespace SpatialBridge.App;

/// <summary>Command-line switches.</summary>
internal sealed record AppOptions(bool Fake, bool SmokeTest, bool Background)
{
    public static AppOptions Parse(IReadOnlyList<string> args) => new(
        args.Contains("--fake") || args.Contains("--smoke-test"),
        args.Contains("--smoke-test"),
        args.Contains("--background"));
}

/// <summary>
/// Owns the tray, windows, overlay and notifications and routes <see cref="IReceiverFacade"/> events to them.
/// All members run on the UI thread; facade events are marshalled onto it.
/// </summary>
internal sealed class AppController : IAsyncDisposable
{
    private static readonly TimeSpan SmokeTestTimeout = TimeSpan.FromSeconds(60);

    private readonly DispatcherQueue _dispatcher;
    private readonly AppOptions _options;
    private readonly Dictionary<Guid, (string Peer, long Bytes)> _transfers = [];
    private readonly Notifier _notifier = new();
    private TrayIconController? _tray;
    private SettingsWindow? _settingsWindow;
    private bool _overlayShowing;
    private bool _smokeSawSuccess;
    private bool _quitting;

    public AppController(DispatcherQueue dispatcher, IReceiverFacade facade, AppOptions options)
    {
        _dispatcher = dispatcher;
        Facade = facade;
        _options = options;
        Overlay = new ArrivalOverlayController(dispatcher);
    }

    public event EventHandler? StateChanged;

    public IReceiverFacade Facade { get; }

    public SettingsStore Settings { get; } = new();

    public HistoryStore History { get; } = new();

    public ArrivalOverlayController Overlay { get; }

    /// <summary>Process exit code (the smoke test reports through it).</summary>
    public int ExitCode { get; private set; }

    public string StatusLine => !Facade.IsAvailable
        ? "Not available"
        : _transfers.Count > 0 ? "Receiving…" : Facade.AllowPairing ? "Available · pairing allowed" : "Available";

    public async Task StartAsync(Microsoft.Windows.AppLifecycle.AppActivationArguments? activation)
    {
        Settings.Load();
        History.Load();
        History.Changed += (_, _) => RaiseStateChanged();

        _notifier.RevealRequested += (_, path) => _dispatcher.TryEnqueue(() => Explorer.Reveal(path));
        _notifier.SettingsRequested += (_, _) => _dispatcher.TryEnqueue(() => OpenSettings(null));
        _notifier.Register();

        Facade.PairingApprover = ApprovePairingAsync;
        Facade.EventRaised += (_, e) => _dispatcher.TryEnqueue(() => Handle(e));

        var folder = Settings.Current.DestinationFolder;
        await Facade.SetDestinationFolderAsync(folder is not null && Directory.Exists(folder) ? folder : AppPaths.DefaultDestination);

        _tray = new TrayIconController(this);
        _tray.Create();

        await Facade.SetAvailableAsync(true);
        if (_options.Fake)
        {
            await Facade.SetAllowPairingAsync(true);
        }
        RaiseStateChanged();
        DiagnosticsLog.Shared.Write($"app.started fake={_options.Fake} packaged={StartupRegistration.IsPackaged}");

        if (activation?.Data is Microsoft.Windows.AppNotifications.AppNotificationActivatedEventArgs notification)
        {
            _notifier.HandleActivation(notification);
        }
        else if (!_options.Background && !_options.SmokeTest)
        {
            OpenSettings(null);
        }

        if (Facade is FakeReceiverFacade fake)
        {
            var script = fake.StartScriptAsync();
            if (_options.SmokeTest)
            {
                _ = RunSmokeTestAsync(fake, script);
            }
        }
    }

    /// <summary>Another launch was redirected here (single instance): show Settings.</summary>
    public void OnRedirectedActivation(Microsoft.Windows.AppLifecycle.AppActivationArguments args)
    {
        if (args.Data is Microsoft.Windows.AppNotifications.AppNotificationActivatedEventArgs notification)
        {
            _notifier.HandleActivation(notification);
            return;
        }
        OpenSettings(null);
    }

    public async Task SetAvailableAsync(bool available)
    {
        await Facade.SetAvailableAsync(available);
        if (!available && Facade.AllowPairing)
        {
            await Facade.SetAllowPairingAsync(false);
        }
        RaiseStateChanged();
    }

    public async Task SetAllowPairingAsync(bool allow)
    {
        await Facade.SetAllowPairingAsync(allow && Facade.IsAvailable);
        RaiseStateChanged();
    }

    public async Task SetDestinationFolderAsync(string folder)
    {
        await Facade.SetDestinationFolderAsync(folder);
        UpdateSettings(s => s.DestinationFolder = folder);
        DiagnosticsLog.Shared.Write("destination.changed");
    }

    public async Task UnpairAsync(string peerID)
    {
        await Facade.UnpairAsync(peerID);
        DiagnosticsLog.Shared.Write("peer.unpaired " + Redaction.Peer(peerID));
        RaiseStateChanged();
    }

    public void UpdateSettings(Action<AppSettings> change)
    {
        change(Settings.Current);
        Settings.Save();
        RaiseStateChanged();
    }

    public Task ChooseFolderAsync()
    {
        var window = OpenSettings(SettingsWindow.General);
        return window.ChooseFolderAsync();
    }

    public SettingsWindow OpenSettings(string? section)
    {
        if (_settingsWindow is null)
        {
            _settingsWindow = new SettingsWindow(this);
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }
        if (section is not null)
        {
            _settingsWindow.Show(section);
        }
        Interop.WindowHelpers.BringToFront(_settingsWindow);
        return _settingsWindow;
    }

    public Task ExportDiagnosticsAsync(string zipPath) =>
        DiagnosticsExporter.ExportAsync(zipPath, Settings.Current, Facade.TrustedPeers.Count, History.Entries, Facade.IsAvailable, Facade.AllowPairing);

    public async Task QuitAsync()
    {
        if (_quitting)
        {
            return;
        }
        _quitting = true;
        await DisposeAsync();
        Application.Current.Exit();
    }

    public async ValueTask DisposeAsync()
    {
        _settingsWindow?.Close();
        _tray?.Dispose();
        _tray = null;
        Overlay.Dispose();
        _notifier.Dispose();
        await Facade.DisposeAsync();
    }

    // MARK: Pairing

    private Task<bool> ApprovePairingAsync(PairingPrompt prompt, CancellationToken cancellationToken)
    {
        var result = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var enqueued = _dispatcher.TryEnqueue(async () =>
        {
            try
            {
                DiagnosticsLog.Shared.Write($"pairing.prompt platform={prompt.Platform.Raw}");
                if (_options.SmokeTest)
                {
                    _ = AutoApproveForSmokeTestAsync();
                }
                var approved = await PairingApprovalWindow.AskAsync(prompt, cancellationToken);
                DiagnosticsLog.Shared.Write("pairing.decision approved=" + approved);
                result.TrySetResult(approved);
            }
            catch (Exception error)
            {
                result.TrySetException(error);
            }
        });
        if (!enqueued)
        {
            result.TrySetResult(false);
        }
        return result.Task;
    }

    private static async Task AutoApproveForSmokeTestAsync()
    {
        await Task.Delay(1500).ConfigureAwait(true);
        PairingApprovalWindow.Pending?.Finish(true);
    }

    // MARK: Receiver events

    private void Handle(ReceiverEvent e)
    {
        switch (e)
        {
            case ReceiverEvent.AvailabilityChanged changed:
                DiagnosticsLog.Shared.Write("availability advertising=" + changed.Advertising);
                break;

            case ReceiverEvent.Paired paired:
                DiagnosticsLog.Shared.Write($"pairing.paired {Redaction.Peer(paired.Peer.PeerID)} platform={paired.Peer.Platform.Raw}");
                _notifier.Post("Paired", $"{paired.Peer.DisplayName} can now send files to this PC.");
                break;

            case ReceiverEvent.PairingFailed failed:
                DiagnosticsLog.Shared.Write("pairing.failed " + failed.Code.ToWire());
                break;

            case ReceiverEvent.PeerConnected connected:
                DiagnosticsLog.Shared.Write("peer.connected " + Redaction.Peer(connected.PeerID));
                break;

            case ReceiverEvent.PeerDisconnected disconnected:
                DiagnosticsLog.Shared.Write("peer.disconnected " + Redaction.Peer(disconnected.PeerID));
                break;

            case ReceiverEvent.TransferIncoming incoming:
                _transfers[incoming.TransferID] = (incoming.PeerDisplayName, incoming.ByteCount);
                DiagnosticsLog.Shared.Write($"transfer.incoming {Redaction.Transfer(incoming.TransferID)} bytes={incoming.ByteCount} edge={incoming.Gesture?.Edge.ToString() ?? "none"}");
                _overlayShowing = Settings.Current.OverlayEnabled
                    && Overlay.ShowIncoming(incoming.TransferID, $"From {incoming.PeerDisplayName} · {UserText.Bytes(incoming.ByteCount)}", incoming.Gesture, Settings.Current.OverlayDisplayId);
                break;

            case ReceiverEvent.TransferProgress progress:
                Overlay.ShowProgress(progress.TransferID, progress.TotalBytes > 0 ? (double)progress.ReceivedBytes / progress.TotalBytes : 0);
                break;

            case ReceiverEvent.TransferCommitted committed:
                OnCommitted(committed);
                break;

            case ReceiverEvent.TransferFailed failed:
                OnFailed(failed);
                break;
        }
        RaiseStateChanged();
    }

    /// <summary>The only place success is shown (AGENTS.md: never before COMMITTED).</summary>
    private void OnCommitted(ReceiverEvent.TransferCommitted committed)
    {
        var peer = _transfers.Remove(committed.TransferID, out var info) ? info.Peer : "your device";
        DiagnosticsLog.Shared.Write($"transfer.committed {Redaction.Transfer(committed.TransferID)} bytes={committed.ByteCount} name={Redaction.Filename(Path.GetFileName(committed.SavedPath))}");
        Overlay.ShowSaved(committed.TransferID, Path.GetFileName(committed.SavedPath));
        if (!_overlayShowing)
        {
            _notifier.PostSaved($"Received from {peer}", committed.SavedPath);
        }
        _overlayShowing = false;
        History.Add(new HistoryEntry(committed.TransferID, DateTimeOffset.Now, peer, committed.ByteCount, committed.SavedPath, null), Settings.Current.KeepHistory);
        if (_options.SmokeTest)
        {
            _smokeSawSuccess = true;
        }
    }

    private void OnFailed(ReceiverEvent.TransferFailed failed)
    {
        var known = _transfers.Remove(failed.TransferID, out var info);
        var peer = known ? info.Peer : "your device";
        DiagnosticsLog.Shared.Write($"transfer.failed {Redaction.Transfer(failed.TransferID)} {failed.Code.ToWire()}");
        Overlay.ShowFailed(failed.TransferID, failed.Code);
        _overlayShowing = false;
        if (failed.Code != BridgeErrorCode.TransferCanceled)
        {
            _notifier.Post($"Transfer from {peer} failed", UserText.Message(failed.Code));
        }
        History.Add(new HistoryEntry(failed.TransferID, DateTimeOffset.Now, peer, known ? info.Bytes : 0, null, failed.Code.ToWire()), Settings.Current.KeepHistory);
    }

    private void RaiseStateChanged()
    {
        _tray?.Refresh();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // MARK: Smoke test (--smoke-test): tray up, pairing window approved, overlay success after COMMITTED, then exit.

    private async Task RunSmokeTestAsync(FakeReceiverFacade fake, Task script)
    {
        var finished = await Task.WhenAny(script, Task.Delay(SmokeTestTimeout)).ConfigureAwait(true);
        var ok = finished == script && script.IsCompletedSuccessfully && fake.ScriptCommitted && _smokeSawSuccess && _tray is not null;
        DiagnosticsLog.Shared.Write("smoke.result ok=" + ok);
        await Task.Delay(1500).ConfigureAwait(true);
        ExitCode = ok ? 0 : 1;
        await QuitAsync();
    }
}
