using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using SpatialBridge.App.Interop;

namespace SpatialBridge.App;

/// <summary>
/// Custom entry point: single instance through <see cref="AppInstance"/> (a second launch is redirected to the
/// running tray app, which opens Settings) before WinUI starts.
/// </summary>
public static class Program
{
    private const string InstanceKey = "SpatialBridge.Receiver";

    [STAThread]
    public static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();

        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        var options = AppOptions.Parse(args);
        // The smoke test must not hand off to a stray instance on the CI machine.
        if (!options.SmokeTest)
        {
            var keyInstance = AppInstance.FindOrRegisterForKey(InstanceKey);
            if (!keyInstance.IsCurrent)
            {
                Redirect(keyInstance, activation);
                return 0;
            }
            keyInstance.Activated += (_, redirected) => OnActivated(redirected);
        }

        App? app = null;
        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            app = new App(options, activation);
        });
        app?.CaptureExitCode();
        return App.ExitCode;
    }

    private static void OnActivated(AppActivationArguments args)
    {
        // Raised on a background thread.
        if (App.CurrentApp is { } app)
        {
            app.UiQueue?.TryEnqueue(() => app.OnRedirected(args));
        }
    }

    /// <summary>Redirects on a worker thread while the STA keeps pumping COM (Windows App SDK guidance).</summary>
    private static void Redirect(AppInstance target, AppActivationArguments activation)
    {
        using var done = new ManualResetEvent(false);
        _ = Task.Run(async () =>
        {
            try
            {
                await target.RedirectActivationToAsync(activation);
            }
            finally
            {
                done.Set();
            }
        });
        WaitPumping(done);
    }

    private static unsafe void WaitPumping(WaitHandle waitHandle)
    {
        var handle = waitHandle.SafeWaitHandle.DangerousGetHandle();
        uint index;
        _ = Win32.CoWaitForMultipleObjects(0, 0xFFFFFFFF, 1, &handle, &index);
    }
}
