using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.AppLifecycle;
using SpatialBridge.App.Fakes;
using SpatialBridge.Core;

namespace SpatialBridge.App;

/// <summary>
/// The WinUI application. Written in code instead of App.xaml so the project has no XAML to compile
/// (the C# then builds on any host); <see cref="XamlControlsResources"/> is merged here instead.
/// A tray app: it keeps running with no windows open until Quit (<see cref="DispatcherShutdownMode.OnExplicitShutdown"/>).
/// </summary>
#pragma warning disable CA1001 // The controller is disposed by AppController.QuitAsync before Exit().
internal sealed partial class App : Application
#pragma warning restore CA1001
{
    private readonly AppOptions _options;
    private readonly AppActivationArguments? _activation;
    private AppController? _controller;

    public App(AppOptions options, AppActivationArguments? activation)
    {
        _options = options;
        _activation = activation;
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) => Services.DiagnosticsLog.Shared.Write("app.unhandled " + e.Exception.GetType().Name);
    }

    public static int ExitCode { get; private set; }

    public static App? CurrentApp => Current as App;

    /// <summary>The UI thread's queue, for callbacks that arrive on other threads.</summary>
    public DispatcherQueue? UiQueue { get; private set; }

    public void OnRedirected(AppActivationArguments args) =>
        _controller?.OnRedirectedActivation(args);

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        Resources.MergedDictionaries.Add(new XamlControlsResources());

        var dispatcher = DispatcherQueue.GetForCurrentThread();
        UiQueue = dispatcher;
        // XP2b swaps this for Core's ReceiverService plus the Platform.Windows services.
        IReceiverFacade facade = new FakeReceiverFacade(scripted: _options.Fake);
        _controller = new AppController(dispatcher, facade, _options);
        await _controller.StartAsync(_activation);
    }

    /// <summary>Called by Program after the message loop ends.</summary>
    public void CaptureExitCode() => ExitCode = _controller?.ExitCode ?? 0;
}
