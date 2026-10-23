using SpatialBridge.Core.Transfer;

namespace SpatialBridge.Platform.Windows.Display;

/// <summary>What the arrival card's kind tile shows (the Mac's <c>ArrivalOverlay.symbol(for:)</c>, plus audio and text).</summary>
public enum ArrivalKind
{
    Document,
    Image,
    Movie,
    Audio,
    Pdf,
    Archive,
    Text,
}

public static class ArrivalKinds
{
    /// <summary>
    /// Classifies by the offered UTI, falling back to the offered filename's extension (Core's UTI catalog, so the
    /// Mac's conformance rules apply). Only the kind leaves this method: the filename itself is never logged.
    /// </summary>
    public static ArrivalKind Classify(string? contentType, string? filename)
    {
        if (!string.IsNullOrEmpty(contentType) && UtiCatalog.IsKnown(contentType))
        {
            return FromUti(contentType);
        }
        var extension = Path.GetExtension(filename ?? string.Empty).TrimStart('.');
        if (extension.Length > 0 && UtiCatalog.TypeForExtension(extension) is { } uti)
        {
            return FromUti(uti);
        }
        return contentType is null ? ArrivalKind.Document : FromUti(contentType);
    }

    private static ArrivalKind FromUti(string uti)
    {
        if (UtiCatalog.ConformsTo(uti, "public.image"))
        {
            return ArrivalKind.Image;
        }
        if (UtiCatalog.ConformsTo(uti, "public.movie"))
        {
            return ArrivalKind.Movie;
        }
        if (UtiCatalog.ConformsTo(uti, "public.audio"))
        {
            return ArrivalKind.Audio;
        }
        if (UtiCatalog.ConformsTo(uti, "com.adobe.pdf"))
        {
            return ArrivalKind.Pdf;
        }
        if (UtiCatalog.ConformsTo(uti, "public.archive"))
        {
            return ArrivalKind.Archive;
        }
        if (UtiCatalog.ConformsTo(uti, "public.text"))
        {
            return ArrivalKind.Text;
        }
        return ArrivalKind.Document;
    }
}
