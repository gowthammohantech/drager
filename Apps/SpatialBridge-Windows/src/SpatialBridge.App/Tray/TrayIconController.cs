using H.NotifyIcon;
using Microsoft.UI;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace SpatialBridge.App.Tray;

/// <summary>
/// Notification-area icon (H.NotifyIcon.WinUI) with the tray menu: Available, Allow Pairing,
/// Choose Save Folder…, Settings…, Quit. Menu items use commands, which work in every H.NotifyIcon menu mode.
/// </summary>
internal sealed class TrayIconController : IDisposable
{
    private readonly AppController _app;
    private readonly TaskbarIcon _icon;
    private readonly MenuFlyoutItem _status = new() { IsEnabled = false };
    private readonly ToggleMenuFlyoutItem _available = new() { Text = "Available" };
    private readonly ToggleMenuFlyoutItem _allowPairing = new() { Text = "Allow Pairing" };

    public TrayIconController(AppController app)
    {
        _app = app;
        _available.Command = new RelayCommand(() => _ = _app.SetAvailableAsync(!_app.Facade.IsAvailable));
        _allowPairing.Command = new RelayCommand(() => _ = _app.SetAllowPairingAsync(!_app.Facade.AllowPairing));

        var menu = new MenuFlyout();
        menu.Items.Add(_status);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(_available);
        menu.Items.Add(_allowPairing);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(new MenuFlyoutItem { Text = "Choose Save Folder…", Command = new RelayCommand(() => _ = _app.ChooseFolderAsync()) });
        menu.Items.Add(new MenuFlyoutItem { Text = "Settings…", Command = new RelayCommand(() => _app.OpenSettings(null)) });
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(new MenuFlyoutItem { Text = "Quit Spatial Bridge", Command = new RelayCommand(() => _ = _app.QuitAsync()) });

        _icon = new TaskbarIcon
        {
            ToolTipText = "Spatial Bridge",
            IconSource = new GeneratedIconSource
            {
                Text = "SB",
                Foreground = new SolidColorBrush(Colors.White),
                Background = new SolidColorBrush(ColorHelper.FromArgb(255, 0x2B, 0x6C, 0xE6)),
                FontSize = 36,
            },
            ContextMenuMode = ContextMenuMode.SecondWindow,
            ContextFlyout = menu,
            NoLeftClickDelay = true,
            LeftClickCommand = new RelayCommand(() => _app.OpenSettings(null)),
        };
        Refresh();
    }

    public void Create() => _icon.ForceCreate(enablesEfficiencyMode: false);

    /// <summary>Syncs the menu with the facade (call on the UI thread).</summary>
    public void Refresh()
    {
        var facade = _app.Facade;
        _available.IsChecked = facade.IsAvailable;
        _allowPairing.IsChecked = facade.AllowPairing;
        _allowPairing.IsEnabled = facade.IsAvailable;
        _status.Text = _app.StatusLine;
        _icon.ToolTipText = "Spatial Bridge — " + _app.StatusLine;
    }

    public void Dispose() => _icon.Dispose();
}
