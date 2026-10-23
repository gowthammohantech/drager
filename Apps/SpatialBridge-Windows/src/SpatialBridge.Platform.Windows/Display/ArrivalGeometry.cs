using SpatialBridge.Core;

namespace SpatialBridge.Platform.Windows.Display;

/// <summary>Axis-aligned rectangle in a top-left-origin space (Windows virtual-screen pixels).</summary>
public readonly record struct RectD(double X, double Y, double Width, double Height)
{
    public double Left => X;

    public double Top => Y;

    public double Right => X + Width;

    public double Bottom => Y + Height;

    public double CenterX => X + (Width / 2);

    public double CenterY => Y + (Height / 2);

    public bool IsEmpty => Width <= 0 || Height <= 0;

    public static RectD FromEdges(double left, double top, double right, double bottom) => new(left, top, right - left, bottom - top);

    public static RectD Centered(double centerX, double centerY, double width, double height) => new(centerX - (width / 2), centerY - (height / 2), width, height);

    public RectD Union(RectD other) => FromEdges(Math.Min(Left, other.Left), Math.Min(Top, other.Top), Math.Max(Right, other.Right), Math.Max(Bottom, other.Bottom));

    public RectD Intersect(RectD other)
    {
        var left = Math.Max(Left, other.Left);
        var top = Math.Max(Top, other.Top);
        var right = Math.Min(Right, other.Right);
        var bottom = Math.Min(Bottom, other.Bottom);
        return right <= left || bottom <= top ? default : FromEdges(left, top, right, bottom);
    }

    public RectD Inflate(double dx, double dy) => new(X - dx, Y - dy, Width + (2 * dx), Height + (2 * dy));
}

/// <summary>
/// One monitor, as the overlay sees it. Frames are in physical pixels of the virtual screen (the process
/// is per-monitor DPI v2 aware); <see cref="Scale"/> is the effective DPI / 96.
/// Mirrors Swift <c>DisplayGeometry</c> with <c>originIsBottomLeft = false</c>.
/// </summary>
public sealed record MonitorGeometry(string Identifier, string Name, RectD Frame, RectD VisibleFrame, double Scale, bool IsPrimary);

/// <summary>Where the arrival card enters and rests. Same meaning as Swift <c>ArrivalPlacement</c>.</summary>
public sealed record ArrivalPlacement(Edge Edge, double EntryX, double EntryY, RectD CardFrame, double NormalizedPosition);

/// <summary>
/// Gesture-to-monitor mapping for the Windows overlay: a top-left-origin port of Swift's
/// <c>CoordinateMapper.placement</c> plus the Mac app's "arrival edge follows the phone's exit edge" rule.
/// XP2b: replace with Core's CoordinateMapper port once Lane N lands it (the coordinate-mapper vectors are the reference).
/// </summary>
public static class ArrivalLayout
{
    /// <summary>The Mac default when the sender sent no gesture: up and out of the phone at 600 pt/s.</summary>
    public static readonly ExitGesture DefaultGesture = new(Edge.Top, 0.5, 600, 0, 0);

    /// <summary>Phone exit edge → receiver arrival edge (phone below the screen ⇒ flick up ⇒ arrives from the bottom).</summary>
    public static Edge ArrivalEdge(Edge exitEdge) => exitEdge switch
    {
        Edge.Top => Edge.Bottom,
        Edge.Bottom => Edge.Top,
        Edge.Left => Edge.Right,
        _ => Edge.Left,
    };

    /// <summary>Swift <c>ExitGesture.intensity</c>: 500 pt/s ≈ 0.33, 1500 pt/s → 1.</summary>
    public static double Intensity(ExitGesture gesture)
    {
        ArgumentNullException.ThrowIfNull(gesture);
        return Math.Clamp(gesture.OutwardVelocity / 1500, 0, 1);
    }

    public static double MapNormalizedPosition(double position, double alignmentOffset = 0, bool mirrored = false)
    {
        var p = Math.Clamp(double.IsNaN(position) ? 0.5 : position, 0, 1);
        if (mirrored)
        {
            p = 1 - p;
        }
        p += Math.Clamp(alignmentOffset, -0.5, 0.5);
        return Math.Clamp(p, 0, 1);
    }

    /// <summary>The preferred monitor, else the primary, else the first.</summary>
    public static MonitorGeometry? SelectMonitor(string? preferredIdentifier, IReadOnlyList<MonitorGeometry> monitors)
    {
        ArgumentNullException.ThrowIfNull(monitors);
        if (preferredIdentifier is not null)
        {
            foreach (var monitor in monitors)
            {
                if (monitor.Identifier == preferredIdentifier)
                {
                    return monitor;
                }
            }
        }
        foreach (var monitor in monitors)
        {
            if (monitor.IsPrimary)
            {
                return monitor;
            }
        }
        return monitors.Count > 0 ? monitors[0] : null;
    }

    /// <param name="cardWidth">Card size in the same pixels as the monitor frames (DIPs × scale).</param>
    /// <param name="restInset">Distance from the visible edge, same pixels.</param>
    public static ArrivalPlacement Place(ExitGesture gesture, MonitorGeometry monitor, double cardWidth, double cardHeight, double restInset, double alignmentOffset = 0, bool mirrored = false)
    {
        ArgumentNullException.ThrowIfNull(gesture);
        ArgumentNullException.ThrowIfNull(monitor);
        var edge = ArrivalEdge(gesture.Edge);
        var mapped = MapNormalizedPosition(gesture.NormalizedPosition, alignmentOffset, mirrored);
        var frame = monitor.Frame;
        var visible = monitor.VisibleFrame;

        double entryX, entryY, restX, restY;
        switch (edge)
        {
            case Edge.Top or Edge.Bottom:
                entryX = restX = frame.Left + (mapped * frame.Width);
                entryY = edge == Edge.Top ? frame.Top : frame.Bottom;
                restY = edge == Edge.Top ? visible.Top + restInset + (cardHeight / 2) : visible.Bottom - restInset - (cardHeight / 2);
                break;
            default:
                entryY = restY = frame.Top + (mapped * frame.Height);
                entryX = edge == Edge.Left ? frame.Left : frame.Right;
                restX = edge == Edge.Left ? visible.Left + restInset + (cardWidth / 2) : visible.Right - restInset - (cardWidth / 2);
                break;
        }

        var x = restX - (cardWidth / 2);
        var y = restY - (cardHeight / 2);
        x = Math.Min(Math.Max(x, visible.Left), Math.Max(visible.Left, visible.Right - cardWidth));
        y = Math.Min(Math.Max(y, visible.Top), Math.Max(visible.Top, visible.Bottom - cardHeight));
        return new ArrivalPlacement(edge, entryX, entryY, new RectD(x, y, cardWidth, cardHeight), mapped);
    }

    /// <summary>The overlay window: card rest frame ∪ entry rect, padded, clipped to the monitor (like the Mac panel).</summary>
    public static RectD OverlayFrame(ArrivalPlacement placement, MonitorGeometry monitor, double padding)
    {
        ArgumentNullException.ThrowIfNull(placement);
        ArgumentNullException.ThrowIfNull(monitor);
        var entry = RectD.Centered(placement.EntryX, placement.EntryY, placement.CardFrame.Width, placement.CardFrame.Height);
        return placement.CardFrame.Union(entry).Inflate(padding, padding).Intersect(monitor.Frame);
    }
}
