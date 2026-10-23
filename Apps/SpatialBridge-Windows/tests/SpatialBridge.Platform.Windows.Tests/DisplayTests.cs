using SpatialBridge.Core;
using SpatialBridge.Core.Calibration;
using SpatialBridge.Platform.Windows.Display;
using SpatialBridge.Platform.Windows.Interop;

namespace SpatialBridge.Platform.Windows.Tests;

public class ArrivalOverlayGeometryTests
{
    private static readonly SizeD Card = new(300, 92);

    private static readonly DisplayGeometry Primary = new(
        @"\\.\DISPLAY1", "Display 1 (main)",
        new RectD(0, 0, 1920, 1080),
        new RectD(0, 0, 1920, 1032), // taskbar at the bottom
        1.0, OriginIsBottomLeft: false, IsMain: true);

    [Theory]
    [InlineData(Edge.Top, Edge.Bottom)]
    [InlineData(Edge.Bottom, Edge.Top)]
    [InlineData(Edge.Left, Edge.Right)]
    [InlineData(Edge.Right, Edge.Left)]
    public void ArrivalEdgeIsOppositeExitEdge(Edge exit, Edge arrival)
    {
        var placement = ArrivalOverlayGeometry.PlacementForExitEdge(exit);
        Assert.Equal(exit, placement.ExitEdge());
        Assert.Equal(arrival, placement.ArrivalEdge());
    }

    [Fact]
    public void FlickUpArrivesFromBottomAboveTaskbar()
    {
        var layout = ArrivalOverlayGeometry.Place(new ExitGesture(Edge.Top, 0.25, 900, 120, 0), [Primary], null, Card, 24, 24)!;
        Assert.Equal(Edge.Bottom, layout.Placement.Edge);
        Assert.Equal(new PointD(480, 1080), layout.Placement.EntryPoint);
        Assert.Equal(new RectD(330, 1032 - 24 - 92, 300, 92), layout.Placement.CardFrame);
    }

    [Fact]
    public void CardIsClampedIntoVisibleFrame()
    {
        var layout = ArrivalOverlayGeometry.Place(new ExitGesture(Edge.Right, 0.0, 900, 120, 0), [Primary], null, Card, 24, 24)!;
        Assert.Equal(Edge.Left, layout.Placement.Edge);
        Assert.Equal(new RectD(24, 0, 300, 92), layout.Placement.CardFrame);
    }

    [Fact]
    public void SizesScaleWithTheMonitorDpi()
    {
        var hiDpi = Primary with { Frame = new RectD(0, 0, 3840, 2160), VisibleFrame = new RectD(0, 0, 3840, 2064), ScaleFactor = 2 };
        var layout = ArrivalOverlayGeometry.Place(new ExitGesture(Edge.Top, 0.5, 900, 120, 0), [hiDpi], null, Card, 24, 24)!;
        Assert.Equal(new RectD(1920 - 300, 2064 - 48 - 184, 600, 184), layout.Placement.CardFrame);
    }

    [Fact]
    public void MirroringAndOffsetFollowCore()
    {
        var layout = ArrivalOverlayGeometry.LayoutFor(new ExitGesture(Edge.Top, 0.3, 0, 0, 0), null, 0.1, mirrored: true);
        Assert.Equal(0.8, CoordinateMapper.MapNormalizedPosition(0.3, layout), 10);
        Assert.Equal(1, CoordinateMapper.MapNormalizedPosition(0.9, ArrivalOverlayGeometry.LayoutFor(ArrivalOverlayGeometry.DefaultGesture, null, 0.5)));
        var nan = ArrivalOverlayGeometry.Place(new ExitGesture(Edge.Top, double.NaN, 900, 0, 0), [Primary], null, Card, 24, 24)!;
        Assert.Equal(0.5, nan.Placement.NormalizedPosition);
    }

    [Fact]
    public void OverlayFrameIsClippedToMonitor()
    {
        var layout = ArrivalOverlayGeometry.Place(null, [Primary], null, Card, 24, 24)!;
        Assert.Equal(1080, layout.WindowFrame.MaxY);
        Assert.True(layout.WindowFrame.MinY < layout.Placement.CardFrame.MinY);
        Assert.Equal(Edge.Bottom, layout.Placement.Edge); // default gesture: flick up
    }

    [Fact]
    public void MonitorSelectionFallsBackToMain()
    {
        var second = Primary with { Identifier = @"\\.\DISPLAY2", Frame = new RectD(1920, 0, 1920, 1080), VisibleFrame = new RectD(1920, 0, 1920, 1080), IsMain = false };
        Assert.Same(second, ArrivalOverlayGeometry.Place(null, [Primary, second], @"\\.\DISPLAY2", Card, 24, 24)!.Display);
        Assert.Same(Primary, ArrivalOverlayGeometry.Place(null, [second, Primary], "gone", Card, 24, 24)!.Display);
        Assert.Null(ArrivalOverlayGeometry.Place(null, [], null, Card, 24, 24));
    }

    [Fact]
    public void IntensityMatchesSwift()
    {
        Assert.Equal(1.0 / 3, ArrivalOverlayGeometry.Intensity(new ExitGesture(Edge.Top, 0.5, 500, 0, 0)), 6);
        Assert.Equal(1, ArrivalOverlayGeometry.Intensity(new ExitGesture(Edge.Top, 0.5, 4000, 0, 0)));
    }

    [Fact]
    public void NativeMonitorInfoMapsToGeometry()
    {
        var monitor = MonitorEnumerator.FromNative(@"\\.\DISPLAY2", new NativeRect { Left = -2560, Top = 0, Right = 0, Bottom = 1440 }, new NativeRect { Left = -2560, Top = 0, Right = 0, Bottom = 1392 }, 144, false, 2);
        Assert.Equal(new RectD(-2560, 0, 2560, 1440), monitor.Frame);
        Assert.Equal(1392, monitor.VisibleFrame.MaxY);
        Assert.Equal(1.5, monitor.ScaleFactor);
        Assert.Equal("Display 2", monitor.LocalizedName);
        Assert.False(monitor.OriginIsBottomLeft);
        Assert.False(monitor.IsMain);
    }

    [WindowsFact]
    public void EnumeratesMonitorsWithoutThrowing()
    {
        foreach (var monitor in MonitorEnumerator.GetMonitors())
        {
            Assert.False(ArrivalOverlayGeometry.IsEmpty(monitor.Frame));
            Assert.True(monitor.ScaleFactor >= 1);
            Assert.False(monitor.OriginIsBottomLeft);
        }
        _ = AnimationSettings.ClientAreaAnimationsEnabled();
    }
}

public class SpringCurveTests
{
    [Fact]
    public void StartsAtZeroAndSettlesAtOne()
    {
        var spring = SpringCurve.ForIntensity(0.5);
        Assert.Equal(0, spring.Value(0));
        var settle = spring.SettleTime();
        Assert.InRange(settle, 0.2, 2.0);
        Assert.Equal(1, spring.Value(settle), 2);
    }

    [Fact]
    public void UnderdampedSpringOvershootsSlightly()
    {
        var spring = SpringCurve.ForIntensity(1);
        var peak = Enumerable.Range(0, 200).Select(i => spring.Value(i / 200.0)).Max();
        Assert.InRange(peak, 1.0, 1.1);
    }

    [Fact]
    public void HarderFlicksAreFaster()
    {
        Assert.True(SpringCurve.ForIntensity(1).SettleTime() < SpringCurve.ForIntensity(0).SettleTime());
        Assert.Equal(0.30, SpringCurve.ForIntensity(1).Response, 10);
        Assert.Equal(0.42, SpringCurve.ForIntensity(0).Response, 10);
    }

    [Fact]
    public void CriticallyDampedHasNoOvershoot()
    {
        var spring = new SpringCurve(0.3, 1.0);
        Assert.All(Enumerable.Range(0, 100), i => Assert.True(spring.Value(i / 50.0) <= 1.0));
    }
}

public class ArrivalKindTests
{
    [Theory]
    [InlineData("public.jpeg", null, ArrivalKind.Image)]
    [InlineData("public.heic", "IMG_0001.HEIC", ArrivalKind.Image)]
    [InlineData("com.apple.quicktime-movie", null, ArrivalKind.Movie)]
    [InlineData("public.mp3", null, ArrivalKind.Audio)]
    [InlineData("com.adobe.pdf", null, ArrivalKind.Pdf)]
    [InlineData("public.zip-archive", null, ArrivalKind.Archive)]
    [InlineData("public.plain-text", null, ArrivalKind.Text)]
    [InlineData(null, "clip.mp4", ArrivalKind.Movie)]
    [InlineData("dyn.ah62d4rv4ge80", "photo.png", ArrivalKind.Image)]
    [InlineData("com.example.unknown", "notes.zzq", ArrivalKind.Document)]
    [InlineData(null, null, ArrivalKind.Document)]
    public void ClassifiesLikeTheMac(string? contentType, string? filename, ArrivalKind expected)
    {
        Assert.Equal(expected, ArrivalKinds.Classify(contentType, filename));
    }
}
