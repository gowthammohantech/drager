using System.Globalization;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using SpatialBridge.App.Interop;
using SpatialBridge.App.Services;
using SpatialBridge.Core;
using SpatialBridge.Platform.Windows.Display;
using SpatialBridge.Platform.Windows.Network;
using Windows.Storage.Pickers;

namespace SpatialBridge.App.Windows;

/// <summary>Settings: General, Devices, Overlay, History, About. Built in code (no XAML) so it compiles on any host.</summary>
internal sealed class SettingsWindow : Window
{
    public const string General = "general";
    public const string Devices = "devices";
    public const string OverlaySection = "overlay";
    public const string History = "history";
    public const string About = "about";

    private readonly AppController _app;
    private readonly NavigationView _navigation;
    private string _section = General;

    public SettingsWindow(AppController app)
    {
        _app = app;
        Title = "Spatial Bridge Settings";
        SystemBackdrop = new MicaBackdrop();

        _navigation = new NavigationView
        {
            PaneDisplayMode = NavigationViewPaneDisplayMode.Left,
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            IsSettingsVisible = false,
            IsPaneToggleButtonVisible = false,
            OpenPaneLength = 200,
        };
        AddItem("General", "", General);
        AddItem("Devices", "", Devices);
        AddItem("Overlay", "", OverlaySection);
        AddItem("History", "", History);
        AddItem("About", "", About);
        _navigation.SelectionChanged += (_, args) =>
        {
            if (args.SelectedItem is NavigationViewItem { Tag: string tag })
            {
                _section = tag;
                Rebuild();
            }
        };
        Content = _navigation;

        _app.StateChanged += OnStateChanged;
        Closed += (_, _) => _app.StateChanged -= OnStateChanged;
        WindowHelpers.SizeAndCenter(this, 860, 600);
        Show(General);
    }

    public void Show(string section)
    {
        foreach (var item in _navigation.MenuItems.OfType<NavigationViewItem>())
        {
            if ((string)item.Tag == section)
            {
                _navigation.SelectedItem = item;
            }
        }
        _section = section;
        Rebuild();
    }

    /// <summary>Choose Save Folder…: a FolderPicker owned by this window's HWND.</summary>
    public async Task ChooseFolderAsync()
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.Downloads };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHelpers.Handle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is not null)
        {
            await _app.SetDestinationFolderAsync(folder.Path);
        }
    }

    private void AddItem(string label, string glyph, string tag) =>
        _navigation.MenuItems.Add(new NavigationViewItem { Content = label, Icon = new FontIcon { Glyph = glyph }, Tag = tag });

    private void OnStateChanged(object? sender, EventArgs e) => DispatcherQueue.TryEnqueue(Rebuild);

    private void Rebuild()
    {
        var body = _section switch
        {
            Devices => BuildDevices(),
            OverlaySection => BuildOverlay(),
            History => BuildHistory(),
            About => BuildAbout(),
            _ => BuildGeneral(),
        };
        _navigation.Content = new ScrollViewer
        {
            Content = new StackPanel { Padding = new Thickness(32, 24, 32, 32), Spacing = 16, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Left, Children = { body } },
        };
    }

    // MARK: General

    private StackPanel BuildGeneral()
    {
        var facade = _app.Facade;
        var panel = Section("General");

        var receiving = new ToggleSwitch { Header = "Receiving", OnContent = "Available to your devices", OffContent = "Not available", IsOn = facade.IsAvailable };
        receiving.Toggled += async (_, _) => await _app.SetAvailableAsync(receiving.IsOn);
        panel.Children.Add(receiving);

        var pairing = new ToggleSwitch { Header = "Allow pairing", OnContent = "New devices can ask to pair", OffContent = "Only paired devices can connect", IsOn = facade.AllowPairing };
        pairing.Toggled += async (_, _) => await _app.SetAllowPairingAsync(pairing.IsOn);
        panel.Children.Add(pairing);

        var folder = facade.DestinationFolder ?? AppPaths.DefaultDestination;
        var change = new Button { Content = "Change…" };
        change.Click += async (_, _) => await ChooseFolderAsync();
        var open = new HyperlinkButton { Content = "Open" };
        open.Click += (_, _) => Explorer.OpenFolder(folder);
        panel.Children.Add(Labeled("Save received files to", new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children = { new TextBlock { Text = folder, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 420 }, change, open },
        }));
        if (!Directory.Exists(folder))
        {
            panel.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Title = "Folder unavailable", Message = UserText.Message(BridgeErrorCode.DestinationPermissionExpired) });
        }

        var startup = new ToggleSwitch { Header = "Start at login", IsEnabled = false };
        panel.Children.Add(startup);
        _ = LoadStartupAsync(startup);

        var firewall = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Warning, Title = "Public network" };
        panel.Children.Add(firewall);
        _ = LoadFirewallAsync(firewall);
        return panel;
    }

    private static async Task LoadStartupAsync(ToggleSwitch toggle)
    {
        try
        {
            toggle.IsOn = await StartupRegistration.IsEnabledAsync();
            toggle.IsEnabled = true;
            toggle.Toggled += async (_, _) =>
            {
                var result = await StartupRegistration.SetEnabledAsync(toggle.IsOn);
                if (result != toggle.IsOn)
                {
                    toggle.IsOn = result; // the user or policy disabled it in Task Manager
                }
            };
        }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException or System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            DiagnosticsLog.Shared.Write("startup.unavailable " + error.GetType().Name);
        }
    }

    private static async Task LoadFirewallAsync(InfoBar bar)
    {
        var status = await FirewallStatus.CheckAsync().ConfigureAwait(true);
        bar.Message = status.Warning ?? string.Empty;
        bar.IsOpen = status.Warning is not null;
    }

    // MARK: Devices

    private StackPanel BuildDevices()
    {
        var panel = Section("Devices");
        var peers = _app.Facade.TrustedPeers;
        if (peers.Count == 0)
        {
            panel.Children.Add(new TextBlock { Text = "No paired devices. Turn on Allow pairing, then pair from the Spatial Bridge app on your phone.", TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
            return panel;
        }
        foreach (var peer in peers.OrderBy(p => p.DisplayName, StringComparer.CurrentCultureIgnoreCase))
        {
            var unpair = new Button { Content = "Unpair" };
            unpair.Click += async (_, _) => await ConfirmUnpairAsync(peer);
            var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(12), CornerRadius = new CornerRadius(6), Background = CardBrush() };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var icon = new FontIcon { Glyph = UserText.PlatformGlyph(peer.Platform), FontSize = 24 };
            var text = new StackPanel
            {
                Children =
                {
                    new TextBlock { Text = peer.DisplayName, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis },
                    new TextBlock { Text = $"{UserText.PlatformName(peer.Platform)} · paired {peer.PairedAt.LocalDateTime.ToString("d", CultureInfo.CurrentCulture)}", Opacity = 0.7 },
                },
            };
            Grid.SetColumn(text, 1);
            Grid.SetColumn(unpair, 2);
            unpair.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(icon);
            row.Children.Add(text);
            row.Children.Add(unpair);
            panel.Children.Add(row);
        }
        return panel;
    }

    private async Task ConfirmUnpairAsync(TrustedPeerInfo peer)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = $"Unpair {peer.DisplayName}?",
            Content = "It will need to pair again before it can send files to this PC.",
            PrimaryButtonText = "Unpair",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await _app.UnpairAsync(peer.PeerID);
        }
    }

    // MARK: Overlay

    private StackPanel BuildOverlay()
    {
        var settings = _app.Settings.Current;
        var panel = Section("Arrival overlay");

        var enabled = new ToggleSwitch { Header = "Show arrival animation", OnContent = "Files fly in from the edge you flick toward", OffContent = "Use notifications instead", IsOn = settings.OverlayEnabled };
        enabled.Toggled += (_, _) => _app.UpdateSettings(s => s.OverlayEnabled = enabled.IsOn);
        panel.Children.Add(enabled);

        var displays = ArrivalOverlayDisplays();
        var combo = new ComboBox { Header = "Display", MinWidth = 280 };
        combo.Items.Add(new ComboBoxItem { Content = "Main display", Tag = null });
        foreach (var display in displays)
        {
            combo.Items.Add(new ComboBoxItem { Content = $"{display.Name} — {display.Frame.Width:0}×{display.Frame.Height:0}", Tag = display.Identifier });
        }
        combo.SelectedIndex = Math.Max(0, displays.ToList().FindIndex(d => d.Identifier == settings.OverlayDisplayId) + 1);
        combo.SelectionChanged += (_, _) =>
        {
            var id = (combo.SelectedItem as ComboBoxItem)?.Tag as string;
            _app.UpdateSettings(s => s.OverlayDisplayId = id);
        };
        panel.Children.Add(combo);

        var test = new Button { Content = "Test Arrival" };
        test.Click += async (_, _) => await _app.Overlay.TestAsync(_app.Settings.Current.OverlayDisplayId, Edge.Top);
        panel.Children.Add(test);

        if (!AnimationSettings.ClientAreaAnimationsEnabled())
        {
            panel.Children.Add(new InfoBar
            {
                IsOpen = true,
                IsClosable = false,
                Severity = InfoBarSeverity.Informational,
                Title = "Animation effects are off",
                Message = "Windows animation effects are turned off, so the card fades in without motion.",
            });
        }
        panel.Children.Add(Note("The overlay is best effort: some full-screen apps can cover it. You always get a notification if a transfer fails."));
        return panel;
    }

    private static IReadOnlyList<MonitorGeometry> ArrivalOverlayDisplays() => MonitorEnumerator.GetMonitors();

    // MARK: History

    private StackPanel BuildHistory()
    {
        var settings = _app.Settings.Current;
        var panel = Section("History");
        var keep = new ToggleSwitch { Header = "Keep history", IsOn = settings.KeepHistory };
        keep.Toggled += (_, _) => _app.UpdateSettings(s => s.KeepHistory = keep.IsOn);
        panel.Children.Add(keep);

        var entries = _app.History.Entries;
        if (entries.Count == 0)
        {
            panel.Children.Add(Note("Nothing received yet."));
            return panel;
        }
        var clear = new Button { Content = "Clear History" };
        clear.Click += (_, _) => _app.History.Clear();
        panel.Children.Add(clear);

        foreach (var entry in entries.Take(100))
        {
            var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(12), CornerRadius = new CornerRadius(6), Background = CardBrush() };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var ok = entry.ErrorCode is null;
            row.Children.Add(new FontIcon { Glyph = ok ? "" : "", Foreground = new SolidColorBrush(ok ? Microsoft.UI.Colors.SeaGreen : Microsoft.UI.Colors.DarkOrange) });
            var title = ok && entry.SavedPath is not null ? Path.GetFileName(entry.SavedPath) : "Not received";
            var detail = $"{entry.Timestamp.LocalDateTime.ToString("g", CultureInfo.CurrentCulture)} · from {entry.PeerDisplayName} · {UserText.Bytes(entry.ByteCount)}";
            if (!ok && BridgeErrorCodes.TryParse(entry.ErrorCode, out var code))
            {
                detail += " · " + UserText.Message(code);
            }
            var text = new StackPanel
            {
                Children =
                {
                    new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis },
                    new TextBlock { Text = detail, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis },
                },
            };
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            if (ok && entry.SavedPath is { } path)
            {
                var reveal = new Button { Content = "Reveal in Explorer", VerticalAlignment = VerticalAlignment.Center };
                reveal.Click += (_, _) => Explorer.Reveal(path);
                Grid.SetColumn(reveal, 2);
                row.Children.Add(reveal);
            }
            panel.Children.Add(row);
        }
        return panel;
    }

    // MARK: About

    private StackPanel BuildAbout()
    {
        var panel = Section("About");
        var version = typeof(SettingsWindow).Assembly.GetName().Version?.ToString(3) ?? "dev";
        panel.Children.Add(new TextBlock { Text = $"Spatial Bridge for Windows {version}", FontWeight = FontWeights.SemiBold });
        panel.Children.Add(Note(StartupRegistration.IsPackaged ? "Installed package" : "Unpackaged build"));
        panel.Children.Add(Note("Files travel directly between your devices over your local network, encrypted end to end. Nothing is uploaded."));

        var status = new TextBlock { Opacity = 0.7 };
        var export = new Button { Content = "Export Diagnostics…" };
        export.Click += async (_, _) =>
        {
            var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.Desktop, SuggestedFileName = $"SpatialBridge-Diagnostics-{DateTime.Now:yyyyMMdd-HHmm}" };
            picker.FileTypeChoices.Add("Zip archive", [".zip"]);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHelpers.Handle(this));
            var file = await picker.PickSaveFileAsync();
            if (file is null)
            {
                return;
            }
            try
            {
                await _app.ExportDiagnosticsAsync(file.Path);
                status.Text = "Diagnostics saved. They contain no file names, file contents, device names or keys.";
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                status.Text = "Couldn't save diagnostics.";
            }
        };
        panel.Children.Add(export);
        panel.Children.Add(status);
        return panel;
    }

    // MARK: Helpers

    private static StackPanel Section(string title) => new()
    {
        Spacing = 16,
        Children = { new TextBlock { Text = title, FontSize = 28, FontWeight = FontWeights.SemiBold } },
    };

    private static StackPanel Labeled(string label, UIElement content) => new()
    {
        Spacing = 6,
        Children = { new TextBlock { Text = label }, content },
    };

    private static TextBlock Note(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };

    private static Brush CardBrush() =>
        Application.Current.Resources.TryGetValue("CardBackgroundFillColorDefaultBrush", out var brush) && brush is Brush b
            ? b
            : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
}
