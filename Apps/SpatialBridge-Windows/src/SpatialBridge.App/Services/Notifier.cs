using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace SpatialBridge.App.Services;

/// <summary>
/// App notifications (AppNotificationManager): the completion fallback when the overlay is off or
/// unavailable (FR-210, ADR-008), failures, and pairing requests. Clicking a "saved" notification reveals the file.
/// </summary>
internal sealed class Notifier : IDisposable
{
    private const string ActionKey = "action";
    private const string PathKey = "path";
    private const string RevealAction = "reveal";
    private const string SettingsAction = "settings";

    private bool _registered;

    public event EventHandler<string>? RevealRequested;

    public event EventHandler? SettingsRequested;

    public void Register()
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked += OnInvoked;
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch (Exception error) when (error is System.Runtime.InteropServices.COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            DiagnosticsLog.Shared.Write("notifications.register-failed " + error.GetType().Name);
        }
    }

    public void PostSaved(string title, string savedPath) =>
        Show(new AppNotificationBuilder()
            .AddArgument(ActionKey, RevealAction)
            .AddArgument(PathKey, savedPath)
            .AddText(title)
            .AddText(Path.GetFileName(savedPath)));

    public void Post(string title, string body) =>
        Show(new AppNotificationBuilder()
            .AddArgument(ActionKey, SettingsAction)
            .AddText(title)
            .AddText(body));

    /// <summary>Handles a launch that came from clicking a notification while the app wasn't running.</summary>
    public void HandleActivation(AppNotificationActivatedEventArgs args) => Dispatch(args.Arguments);

    public void Dispose()
    {
        if (_registered)
        {
            AppNotificationManager.Default.NotificationInvoked -= OnInvoked;
            try
            {
                AppNotificationManager.Default.Unregister();
            }
            catch (System.Runtime.InteropServices.COMException)
            {
            }
            _registered = false;
        }
    }

    private void Show(AppNotificationBuilder builder)
    {
        if (!_registered)
        {
            return;
        }
        try
        {
            AppNotificationManager.Default.Show(builder.BuildNotification());
        }
        catch (Exception error) when (error is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            DiagnosticsLog.Shared.Write("notifications.show-failed " + error.GetType().Name);
        }
    }

    private void OnInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args) => Dispatch(args.Arguments);

    private void Dispatch(IDictionary<string, string> arguments)
    {
        if (!arguments.TryGetValue(ActionKey, out var action))
        {
            return;
        }
        if (action == RevealAction && arguments.TryGetValue(PathKey, out var path))
        {
            RevealRequested?.Invoke(this, path);
        }
        else
        {
            SettingsRequested?.Invoke(this, EventArgs.Empty);
        }
    }
}
