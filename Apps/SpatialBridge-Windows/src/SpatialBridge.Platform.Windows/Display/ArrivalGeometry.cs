using SpatialBridge.Core;
using SpatialBridge.Core.Calibration;

namespace SpatialBridge.Platform.Windows.Display;

/// <summary>Everything the overlay needs to show one arrival: the chosen monitor, Core's placement and the window frame.</summary>
/// <param name="Display">The monitor (physical pixels of the virtual screen, top-left origin).</param>
/// <param name="Placement">Core's <see cref="CoordinateMapper.Placement"/> result, in the same pixels.</param>
/// <param name="WindowFrame">The layered window: card rest frame ∪ entry rect, padded, clipped to the monitor.</param>
public sealed record OverlayLayout(DisplayGeometry Display, ArrivalPlacement Placement, RectD WindowFrame);

/// <summary>
/// Windows glue around Core's <see cref="CoordinateMapper"/> (the coordinate-mapper vectors are its reference).
/// Displays come from <see cref="MonitorEnumerator"/> with <c>OriginIsBottomLeft = false</c>. Their frames are
/// physical pixels (the process is per-monitor DPI v2 aware), so card sizes and insets given in DIPs are scaled by
/// the chosen monitor's <see cref="DisplayGeometry.ScaleFactor"/> before mapping; the mapping itself is linear.
/// Like the Mac app, the arrival edge follows the phone's exit edge; display, nudge and mirroring are preferences.
/// </summary>
public static class ArrivalOverlayGeometry
{
    /// <summary>The Mac default when the sender sent no gesture: up and out of the phone at 600 pt/s.</summary>
    public static readonly ExitGesture DefaultGesture = new(Edge.Top, 0.5, 600, 0, 0);

    /// <summary>Inverse of <see cref="PhonePlacements.ExitEdge"/>: a flick up out of the phone means the phone sits below.</summary>
    public static PhonePlacement PlacementForExitEdge(Edge exitEdge) => exitEdge switch
    {
        Edge.Top => PhonePlacement.Below,
        Edge.Bottom => PhonePlacement.Above,
        Edge.Right => PhonePlacement.Left,
        _ => PhonePlacement.Right,
    };

    public static SpatialLayout LayoutFor(ExitGesture gesture, string? displayIdentifier, double alignmentOffset = 0, bool mirrored = false)
    {
        ArgumentNullException.ThrowIfNull(gesture);
        return new SpatialLayout(PlacementForExitEdge(gesture.Edge), displayIdentifier, alignmentOffset, mirrored);
    }

    /// <summary>Swift <c>ExitGesture.intensity</c>: 500 pt/s ≈ 0.33, 1500 pt/s → 1.</summary>
    public static double Intensity(ExitGesture gesture)
    {
        ArgumentNullException.ThrowIfNull(gesture);
        return double.IsFinite(gesture.OutwardVelocity) ? Math.Clamp(gesture.OutwardVelocity / 1500, 0, 1) : 0;
    }

    /// <summary>
    /// Maps <paramref name="gesture"/> (or <see cref="DefaultGesture"/>) onto the preferred monitor, else the main one.
    /// Returns null when there is no monitor or the window frame would be empty.
    /// </summary>
    public static OverlayLayout? Place(
        ExitGesture? gesture,
        IReadOnlyList<DisplayGeometry> displays,
        string? displayIdentifier,
        SizeD cardSizeDips,
        double restInsetDips,
        double paddingDips,
        double alignmentOffset = 0,
        bool mirrored = false)
    {
        ArgumentNullException.ThrowIfNull(displays);
        var exit = gesture ?? DefaultGesture;
        var layout = LayoutFor(exit, displayIdentifier, alignmentOffset, mirrored);
        if (CoordinateMapper.SelectDisplay(layout, displays) is not { } display)
        {
            return null;
        }
        var scale = display.ScaleFactor > 0 && double.IsFinite(display.ScaleFactor) ? display.ScaleFactor : 1;
        var position = double.IsFinite(exit.NormalizedPosition) ? exit.NormalizedPosition : 0.5;
        var card = new SizeD(cardSizeDips.Width * scale, cardSizeDips.Height * scale);
        var placement = CoordinateMapper.Placement(position, layout, display, card, restInsetDips * scale);
        var frame = OverlayFrame(placement, display, paddingDips * scale);
        return IsEmpty(frame) ? null : new OverlayLayout(display, placement, frame);
    }

    /// <summary>The overlay window: card rest frame ∪ entry rect, padded, clipped to the monitor (like the Mac panel).</summary>
    public static RectD OverlayFrame(ArrivalPlacement placement, DisplayGeometry display, double padding)
    {
        ArgumentNullException.ThrowIfNull(placement);
        ArgumentNullException.ThrowIfNull(display);
        var card = placement.CardFrame;
        var entry = new RectD(placement.EntryPoint.X - (card.Width / 2), placement.EntryPoint.Y - (card.Height / 2), card.Width, card.Height);
        return Intersect(Inflate(Union(card, entry), padding), display.Frame);
    }

    public static bool IsEmpty(RectD rect) => !(Math.Abs(rect.Width) > 0 && Math.Abs(rect.Height) > 0);

    private static RectD FromEdges(double left, double top, double right, double bottom) => new(left, top, right - left, bottom - top);

    private static RectD Union(RectD a, RectD b) =>
        FromEdges(Math.Min(a.MinX, b.MinX), Math.Min(a.MinY, b.MinY), Math.Max(a.MaxX, b.MaxX), Math.Max(a.MaxY, b.MaxY));

    private static RectD Inflate(RectD r, double d) => FromEdges(r.MinX - d, r.MinY - d, r.MaxX + d, r.MaxY + d);

    private static RectD Intersect(RectD a, RectD b)
    {
        var left = Math.Max(a.MinX, b.MinX);
        var top = Math.Max(a.MinY, b.MinY);
        var right = Math.Min(a.MaxX, b.MaxX);
        var bottom = Math.Min(a.MaxY, b.MaxY);
        return right <= left || bottom <= top ? default : FromEdges(left, top, right, bottom);
    }
}
