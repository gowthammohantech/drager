using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace SpatialBridge.App.Interop;

internal static class WindowHelpers
{
    public static nint Handle(Window window) => WinRT.Interop.WindowNative.GetWindowHandle(window);

    public static double Scale(Window window)
    {
        var dpi = Win32.GetDpiForWindow(Handle(window));
        return dpi == 0 ? 1 : dpi / 96.0;
    }

    /// <summary>Sizes in DIPs (AppWindow works in physical pixels) and centres on the window's display.</summary>
    public static void SizeAndCenter(Window window, int widthDips, int heightDips)
    {
        var scale = Scale(window);
        var size = new SizeInt32((int)(widthDips * scale), (int)(heightDips * scale));
        var appWindow = window.AppWindow;
        appWindow.Resize(size);
        var area = DisplayArea.GetFromWindowId(appWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        appWindow.Move(new PointInt32(area.X + ((area.Width - size.Width) / 2), area.Y + ((area.Height - size.Height) / 2)));
    }

    public static void BringToFront(Window window)
    {
        window.Activate();
        Win32.SetForegroundWindow(Handle(window));
    }

    /// <summary>A fixed dialog-style window: no resize, minimise or maximise.</summary>
    public static void MakeDialog(Window window, bool alwaysOnTop)
    {
        if (window.AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMinimizable = false;
            presenter.IsMaximizable = false;
            presenter.IsAlwaysOnTop = alwaysOnTop;
        }
    }

    public static WindowId Id(Window window) => window.AppWindow.Id;
}
