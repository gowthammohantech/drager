using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using SpatialBridge.App.Interop;
using SpatialBridge.App.Services;
using SpatialBridge.Core;

namespace SpatialBridge.App.Windows;

/// <summary>
/// Asks the user to compare the 6-digit code with the phone (driven by <see cref="IReceiverFacade.PairingApprover"/>).
/// Closing the window, "Codes Don't Match" or the caller's cancellation (decision timeout) all mean "no".
/// </summary>
internal sealed class PairingApprovalWindow : Window
{
    private readonly TaskCompletionSource<bool> _result = new(TaskCreationOptions.RunContinuationsAsynchronously);

    private PairingApprovalWindow(PairingPrompt prompt)
    {
        Title = "Pair with Spatial Bridge";
        ExtendsContentIntoTitleBar = false;
        SystemBackdrop = new MicaBackdrop();

        var platform = UserText.PlatformName(prompt.Platform);
        var approve = new Button
        {
            Content = "Approve",
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        approve.Click += (_, _) => Finish(true);
        var reject = new Button { Content = "Codes Don't Match", HorizontalAlignment = HorizontalAlignment.Stretch };
        reject.Click += (_, _) => Finish(false);

        var buttons = new Grid { ColumnSpacing = 8 };
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(approve, 1);
        buttons.Children.Add(reject);
        buttons.Children.Add(approve);

        Content = new StackPanel
        {
            Padding = new Thickness(24),
            Spacing = 12,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 12,
                    Children =
                    {
                        new FontIcon { Glyph = UserText.PlatformGlyph(prompt.Platform), FontSize = 28 },
                        new StackPanel
                        {
                            Children =
                            {
                                new TextBlock { Text = prompt.PeerDisplayName, FontSize = 18, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis },
                                new TextBlock { Text = $"{char.ToUpperInvariant(platform[0])}{platform[1..]} wants to pair", Opacity = 0.7 },
                            },
                        },
                    },
                },
                new TextBlock
                {
                    Text = UserText.FormatCode(prompt.Code),
                    FontSize = 40,
                    FontWeight = FontWeights.SemiBold,
                    FontFamily = new FontFamily("Consolas"),
                    CharacterSpacing = 120,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Margin = new Thickness(0, 8, 0, 8),
                },
                new TextBlock
                {
                    Text = $"Approve only if your {platform} shows the same code.",
                    TextWrapping = TextWrapping.Wrap,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    TextAlignment = TextAlignment.Center,
                },
                buttons,
            },
        };

        Closed += (_, _) => _result.TrySetResult(false);
        WindowHelpers.MakeDialog(this, alwaysOnTop: true);
        WindowHelpers.SizeAndCenter(this, 420, 330);
    }

    /// <summary>The window currently asking, if any (used by the smoke test).</summary>
    public static PairingApprovalWindow? Pending { get; private set; }

    /// <summary>Shows the prompt; must be called on the UI thread.</summary>
    public static async Task<bool> AskAsync(PairingPrompt prompt, CancellationToken cancellationToken)
    {
        var window = new PairingApprovalWindow(prompt);
        Pending = window;
        using var registration = cancellationToken.Register(() => window.DispatcherQueue.TryEnqueue(() => window.Finish(false)));
        WindowHelpers.BringToFront(window);
        try
        {
            return await window._result.Task.ConfigureAwait(true);
        }
        finally
        {
            if (ReferenceEquals(Pending, window))
            {
                Pending = null;
            }
        }
    }

    public void Finish(bool approved)
    {
        if (_result.TrySetResult(approved))
        {
            Close();
        }
    }
}
