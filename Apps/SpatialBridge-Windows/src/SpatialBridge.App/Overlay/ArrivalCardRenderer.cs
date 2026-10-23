using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using SpatialBridge.Core;
using SpatialBridge.App.Services;
using SpatialBridge.Platform.Windows.Display;

namespace SpatialBridge.App.Overlay;

/// <summary>What the card currently shows (Mac <c>ArrivalPhase</c>).</summary>
internal abstract record ArrivalPhase
{
    private ArrivalPhase() { }

    public sealed record Incoming(double Progress) : ArrivalPhase;
    public sealed record Verifying : ArrivalPhase;
    public sealed record Saved(string Name) : ArrivalPhase;
    public sealed record Failed(BridgeErrorCode Code) : ArrivalPhase;
}

internal sealed record CardFrame(
    ArrivalPhase Phase,
    ArrivalKind Kind,
    string Subtitle,
    double CenterX,
    double CenterY,
    double CardScale,
    double StatusIconScale,
    double Scale);

/// <summary>Draws the dark arrival card (300 × 92 DIPs, like the Mac) into the layered window's DIB with GDI+.</summary>
internal static class ArrivalCardRenderer
{
    public const double CardWidth = 300;
    public const double CardHeight = 92;

    public static void Render(nint bits, int width, int height, CardFrame frame)
    {
        using var bitmap = new Bitmap(width, height, width * 4, PixelFormat.Format32bppPArgb, bits);
        using var g = Graphics.FromImage(bitmap);
        g.CompositingMode = CompositingMode.SourceCopy;
        g.Clear(Color.Transparent);
        g.CompositingMode = CompositingMode.SourceOver;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;

        var s = frame.Scale;
        g.TranslateTransform((float)frame.CenterX, (float)frame.CenterY);
        g.ScaleTransform((float)(frame.CardScale * s), (float)(frame.CardScale * s));
        g.TranslateTransform((float)(-CardWidth / 2), (float)(-CardHeight / 2));

        var card = new RectangleF(0, 0, (float)CardWidth, (float)CardHeight);

        // Soft shadow (approximation of the Mac's radius-18 shadow).
        for (var i = 6; i >= 1; i--)
        {
            using var shadowPath = RoundedRect(RectangleF.Inflate(new RectangleF(card.X, card.Y + 6, card.Width, card.Height), i * 2, i * 2), 16 + (i * 2));
            using var shadow = new SolidBrush(Color.FromArgb(10, 0, 0, 0));
            g.FillPath(shadow, shadowPath);
        }

        using (var path = RoundedRect(card, 16))
        using (var fill = new SolidBrush(Color.FromArgb(235, 22, 22, 26)))
        using (var border = new Pen(Color.FromArgb(31, 255, 255, 255), 1))
        {
            g.FillPath(fill, path);
            g.DrawPath(border, path);
        }

        // Kind tile with a document glyph.
        var tile = new RectangleF(14, 16, 60, 60);
        using (var tilePath = RoundedRect(tile, 10))
        using (var tileFill = new SolidBrush(Color.FromArgb(31, 255, 255, 255)))
        {
            g.FillPath(tileFill, tilePath);
        }
        using (var glyphFont = new Font("Segoe MDL2 Assets", 20, FontStyle.Regular, GraphicsUnit.Pixel))
        using (var white = new SolidBrush(Color.White))
        using (var centered = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
        {
            g.DrawString(GlyphFor(frame.Phase, frame.Kind), glyphFont, white, tile, centered);
        }

        // Text column.
        var textLeft = 86f;
        var textWidth = (float)CardWidth - textLeft - 44;
        using (var titleFont = new Font("Segoe UI Semibold", 14, FontStyle.Regular, GraphicsUnit.Pixel))
        using (var subtitleFont = new Font("Segoe UI", 12, FontStyle.Regular, GraphicsUnit.Pixel))
        using (var white = new SolidBrush(Color.White))
        using (var dim = new SolidBrush(Color.FromArgb(191, 255, 255, 255)))
        using (var ellipsis = new StringFormat(StringFormatFlags.NoWrap) { Trimming = StringTrimming.EllipsisCharacter })
        using (var middle = new StringFormat(StringFormatFlags.NoWrap) { Trimming = StringTrimming.EllipsisPath })
        {
            g.DrawString(Title(frame.Phase), titleFont, white, new RectangleF(textLeft, 18, textWidth, 20), ellipsis);
            var subtitle = frame.Phase is ArrivalPhase.Saved saved ? saved.Name : frame.Subtitle;
            g.DrawString(subtitle, subtitleFont, dim, new RectangleF(textLeft, 40, textWidth, 18), middle);
        }

        // Progress bar while incoming/verifying.
        if (frame.Phase is ArrivalPhase.Incoming or ArrivalPhase.Verifying)
        {
            var track = new RectangleF(textLeft, 64, textWidth, 4);
            using var trackPath = RoundedRect(track, 2);
            using var trackFill = new SolidBrush(Color.FromArgb(64, 255, 255, 255));
            g.FillPath(trackFill, trackPath);
            var fraction = frame.Phase is ArrivalPhase.Incoming incoming ? Math.Clamp(incoming.Progress, 0, 1) : 1;
            if (fraction > 0)
            {
                using var barPath = RoundedRect(new RectangleF(track.X, track.Y, Math.Max(4, track.Width * (float)fraction), track.Height), 2);
                using var barFill = new SolidBrush(Color.FromArgb(frame.Phase is ArrivalPhase.Verifying ? 160 : 255, 255, 255, 255));
                g.FillPath(barFill, barPath);
            }
        }

        // Status icon on the right: only after COMMITTED (Saved) or on failure.
        var iconCenter = new PointF((float)CardWidth - 26, (float)CardHeight / 2);
        var iconScale = (float)Math.Max(0, frame.StatusIconScale);
        if (frame.Phase is ArrivalPhase.Saved && iconScale > 0)
        {
            var r = 11 * iconScale;
            using var green = new SolidBrush(Color.FromArgb(255, 52, 199, 89));
            g.FillEllipse(green, iconCenter.X - r, iconCenter.Y - r, 2 * r, 2 * r);
            using var tick = new Pen(Color.White, 2.4f * iconScale) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
            g.DrawLines(tick,
            [
                new PointF(iconCenter.X - (5 * iconScale), iconCenter.Y),
                new PointF(iconCenter.X - (1.5f * iconScale), iconCenter.Y + (4 * iconScale)),
                new PointF(iconCenter.X + (5.5f * iconScale), iconCenter.Y - (4 * iconScale)),
            ]);
        }
        else if (frame.Phase is ArrivalPhase.Failed)
        {
            using var orange = new SolidBrush(Color.FromArgb(255, 255, 149, 0));
            g.FillPolygon(orange,
            [
                new PointF(iconCenter.X, iconCenter.Y - 11),
                new PointF(iconCenter.X + 12, iconCenter.Y + 10),
                new PointF(iconCenter.X - 12, iconCenter.Y + 10),
            ]);
            using var bang = new Font("Segoe UI", 13, FontStyle.Bold, GraphicsUnit.Pixel);
            using var black = new SolidBrush(Color.FromArgb(255, 30, 30, 30));
            using var centered = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString("!", bang, black, new RectangleF(iconCenter.X - 8, iconCenter.Y - 6, 16, 16), centered);
        }
    }

    public static string Title(ArrivalPhase phase) => phase switch
    {
        ArrivalPhase.Incoming => "Receiving…",
        ArrivalPhase.Verifying => "Verifying…",
        ArrivalPhase.Saved => "Saved",
        ArrivalPhase.Failed failed => UserText.Message(failed.Code),
        _ => string.Empty,
    };

    /// <summary>Segoe MDL2 glyph for the kind tile: Warning on failure, else by kind (from the offered UTI or extension).</summary>
    private static string GlyphFor(ArrivalPhase phase, ArrivalKind kind) => phase is ArrivalPhase.Failed
        ? "\uE7BA" // Warning
        : kind switch
        {
            ArrivalKind.Image => "\uEB9F", // Photo2
            ArrivalKind.Movie => "\uE714", // Video
            ArrivalKind.Audio => "\uE8D6", // Audio
            ArrivalKind.Pdf => "\uEA90", // PDF
            ArrivalKind.Archive => "\uF012", // ZipFolder
            ArrivalKind.Text => "\uE7C3", // Page
            _ => "\uE8A5", // Document
        };

    private static GraphicsPath RoundedRect(RectangleF rect, float radius)
    {
        var d = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));
        var path = new GraphicsPath();
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
