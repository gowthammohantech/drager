namespace SpatialBridge.Core.Calibration;

public readonly record struct PointD(double X, double Y);

public readonly record struct SizeD(double Width, double Height);

public readonly record struct RectD(double X, double Y, double Width, double Height)
{
    public double MinX => Width >= 0 ? X : X + Width;
    public double MinY => Height >= 0 ? Y : Y + Height;
    public double MaxX => MinX + Math.Abs(Width);
    public double MaxY => MinY + Math.Abs(Height);
    public double MidX => MinX + (Math.Abs(Width) / 2);
    public double MidY => MinY + (Math.Abs(Height) / 2);
}

/// <summary>Where the phone sits relative to the computer display (ADR-004).</summary>
public enum PhonePlacement { Below, Above, Left, Right }

public static class PhonePlacements
{
    public static Edge ExitEdge(this PhonePlacement p) => p switch
    {
        PhonePlacement.Below => Edge.Top,
        PhonePlacement.Above => Edge.Bottom,
        PhonePlacement.Left => Edge.Right,
        _ => Edge.Left,
    };

    public static Edge ArrivalEdge(this PhonePlacement p) => p switch
    {
        PhonePlacement.Below => Edge.Bottom,
        PhonePlacement.Above => Edge.Top,
        PhonePlacement.Left => Edge.Left,
        _ => Edge.Right,
    };
}

public sealed record SpatialLayout
{
    public SpatialLayout(PhonePlacement placement = PhonePlacement.Below, string? displayIdentifier = null, double alignmentOffset = 0, bool mirrored = false)
    {
        Placement = placement;
        DisplayIdentifier = displayIdentifier;
        AlignmentOffset = Math.Min(Math.Max(alignmentOffset, -0.5), 0.5);
        Mirrored = mirrored;
    }

    public PhonePlacement Placement { get; }
    public string? DisplayIdentifier { get; }
    public double AlignmentOffset { get; }
    public bool Mirrored { get; }
    public Edge ArrivalEdge => Placement.ArrivalEdge();
}

/// <summary>Display geometry captured by the app layer. On Windows, use top-left origin (<see cref="OriginIsBottomLeft"/> false) in DIPs.</summary>
public sealed record DisplayGeometry(string Identifier, string LocalizedName, RectD Frame, RectD VisibleFrame, double ScaleFactor, bool OriginIsBottomLeft, bool IsMain);

public sealed record ArrivalPlacement(Edge Edge, PointD EntryPoint, PointD RestPoint, RectD CardFrame, double NormalizedPosition);

/// <summary>Pure mapping from a sender gesture to a receiver placement (FRD §6), ported from Swift.</summary>
public static class CoordinateMapper
{
    public static double MapNormalizedPosition(double position, SpatialLayout layout)
    {
        var p = Math.Min(Math.Max(position, 0), 1);
        if (layout.Mirrored) p = 1 - p;
        p += layout.AlignmentOffset;
        return Math.Min(Math.Max(p, 0), 1);
    }

    public static DisplayGeometry? SelectDisplay(SpatialLayout layout, IReadOnlyList<DisplayGeometry> displays)
    {
        if (layout.DisplayIdentifier is { } id && displays.FirstOrDefault(d => d.Identifier == id) is { } match) return match;
        return displays.FirstOrDefault(d => d.IsMain) ?? (displays.Count > 0 ? displays[0] : null);
    }

    public static ArrivalPlacement Placement(double gesturePosition, SpatialLayout layout, DisplayGeometry display, SizeD cardSize, double restInset = 24)
    {
        var edge = layout.ArrivalEdge;
        var mapped = MapNormalizedPosition(gesturePosition, layout);
        var frame = display.Frame;
        var visible = display.VisibleFrame;
        var alongVertical = display.OriginIsBottomLeft ? 1 - mapped : mapped;

        PointD entry, rest;
        if (edge is Edge.Top or Edge.Bottom)
        {
            var x = frame.MinX + (mapped * frame.Width);
            var isTop = edge == Edge.Top;
            double edgeY, restY;
            if (display.OriginIsBottomLeft)
            {
                edgeY = isTop ? frame.MaxY : frame.MinY;
                restY = isTop ? visible.MaxY - restInset - (cardSize.Height / 2) : visible.MinY + restInset + (cardSize.Height / 2);
            }
            else
            {
                edgeY = isTop ? frame.MinY : frame.MaxY;
                restY = isTop ? visible.MinY + restInset + (cardSize.Height / 2) : visible.MaxY - restInset - (cardSize.Height / 2);
            }
            entry = new PointD(x, edgeY);
            rest = new PointD(x, restY);
        }
        else
        {
            var y = frame.MinY + (alongVertical * frame.Height);
            var edgeX = edge == Edge.Left ? frame.MinX : frame.MaxX;
            var restX = edge == Edge.Left ? visible.MinX + restInset + (cardSize.Width / 2) : visible.MaxX - restInset - (cardSize.Width / 2);
            entry = new PointD(edgeX, y);
            rest = new PointD(restX, y);
        }

        var cardX = rest.X - (cardSize.Width / 2);
        var cardY = rest.Y - (cardSize.Height / 2);
        cardX = Math.Min(Math.Max(cardX, visible.MinX), Math.Max(visible.MinX, visible.MaxX - cardSize.Width));
        cardY = Math.Min(Math.Max(cardY, visible.MinY), Math.Max(visible.MinY, visible.MaxY - cardSize.Height));
        var card = new RectD(cardX, cardY, cardSize.Width, cardSize.Height);
        return new ArrivalPlacement(edge, entry, new PointD(card.MidX, card.MidY), card, mapped);
    }
}
