using SpatialBridge.Core;
using SpatialBridge.Platform.Windows.Display;
using SpatialBridge.Platform.Windows.Interop;

namespace SpatialBridge.Platform.Windows.Tests;

public class ArrivalLayoutTests
{
    private static readonly MonitorGeometry Primary = new(
        @"\\.\DISPLAY1", "Display 1 (main)",
        new RectD(0, 0, 1920, 1080),
        new RectD(0, 0, 1920, 1032), // taskbar at the bottom
        1.0, true);

    [Theory]
    [InlineData(Edge.Top, Edge.Bottom)]
    [InlineData(Edge.Bottom, Edge.Top)]
    [InlineData(Edge.Left, Edge.Right)]
    [InlineData(Edge.Right, Edge.Left)]
    public void ArrivalEdgeIsOppositeExitEdge(Edge exit, Edge arrival)
    {
        Assert.Equal(arrival, ArrivalLayout.ArrivalEdge(exit));
    }

    [Fact]
    public void FlickUpArrivesFromBottomAboveTaskbar()
    {
        var gesture = new ExitGesture(Edge.Top, 0.25, 900, 120, 0);
        var placement = ArrivalLayout.Place(gesture, Primary, 300, 92, 24);
        Assert.Equal(Edge.Bottom, placement.Edge);
        Assert.Equal(480, placement.EntryX);
        Assert.Equal(1080, placement.EntryY);
        Assert.Equal(new RectD(330, 1032 - 24 - 92, 300, 92), placement.CardFrame);
    }

    [Fact]
    public void CardIsClampedIntoVisibleFrame()
    {
        var gesture = new ExitGesture(Edge.Right, 0.0, 900, 120, 0);
        var placement = ArrivalLayout.Place(gesture, Primary, 300, 92, 24);
        Assert.Equal(Edge.Left, placement.Edge);
        Assert.Equal(new RectD(24, 0, 300, 92), placement.CardFrame);
    }

    [Fact]
    public void MirroringAndOffsetApply()
    {
        Assert.Equal(0.8, ArrivalLayout.MapNormalizedPosition(0.3, 0.1, mirrored: true), 10);
        Assert.Equal(1, ArrivalLayout.MapNormalizedPosition(0.9, 0.5));
        Assert.Equal(0.5, ArrivalLayout.MapNormalizedPosition(double.NaN));
    }

    [Fact]
    public void OverlayFrameIsClippedToMonitor()
    {
        var placement = ArrivalLayout.Place(ArrivalLayout.DefaultGesture, Primary, 300, 92, 24);
        var frame = ArrivalLayout.OverlayFrame(placement, Primary, 24);
        Assert.Equal(1080, frame.Bottom);
        Assert.True(frame.Top < placement.CardFrame.Top);
    }

    [Fact]
    public void MonitorSelectionFallsBackToPrimary()
    {
        var second = Primary with { Identifier = @"\\.\DISPLAY2", IsPrimary = false };
        Assert.Same(second, ArrivalLayout.SelectMonitor(@"\\.\DISPLAY2", [Primary, second]));
        Assert.Same(Primary, ArrivalLayout.SelectMonitor("gone", [second, Primary]));
        Assert.Null(ArrivalLayout.SelectMonitor(null, []));
    }

    [Fact]
    public void IntensityMatchesSwift()
    {
        Assert.Equal(1.0 / 3, ArrivalLayout.Intensity(new ExitGesture(Edge.Top, 0.5, 500, 0, 0)), 6);
        Assert.Equal(1, ArrivalLayout.Intensity(new ExitGesture(Edge.Top, 0.5, 4000, 0, 0)));
    }

    [Fact]
    public void NativeMonitorInfoMapsToGeometry()
    {
        var monitor = MonitorEnumerator.FromNative(@"\\.\DISPLAY2", new NativeRect { Left = -2560, Top = 0, Right = 0, Bottom = 1440 }, new NativeRect { Left = -2560, Top = 0, Right = 0, Bottom = 1392 }, 144, false, 2);
        Assert.Equal(new RectD(-2560, 0, 2560, 1440), monitor.Frame);
        Assert.Equal(1392, monitor.VisibleFrame.Bottom);
        Assert.Equal(1.5, monitor.Scale);
        Assert.Equal("Display 2", monitor.Name);
    }

    [WindowsFact]
    public void EnumeratesMonitorsWithoutThrowing()
    {
        foreach (var monitor in MonitorEnumerator.GetMonitors())
        {
            Assert.False(monitor.Frame.IsEmpty);
            Assert.True(monitor.Scale >= 1);
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
