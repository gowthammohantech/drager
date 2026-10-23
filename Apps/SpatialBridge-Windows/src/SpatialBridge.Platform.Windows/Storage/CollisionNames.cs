using System.Globalization;

namespace SpatialBridge.Platform.Windows.Storage;

/// <summary>Collision-safe candidate names, like Swift <c>FilenameSanitizer.candidate</c>: "photo.jpg", "photo 2.jpg", "photo 3.jpg"…</summary>
public static class CollisionNames
{
    /// <summary>NTFS limit for one path component, in UTF-16 code units.</summary>
    public const int MaxNameLength = 255;

    public const string FallbackBaseName = "Received file";

    public static string Candidate(string name, int attempt)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        if (attempt <= 1)
        {
            return name;
        }
        var (stem, extension) = Split(name);
        // Unlike a plain truncate of "stem N", the counter is always kept so long names still get distinct candidates.
        var counter = " " + attempt.ToString(CultureInfo.InvariantCulture);
        return Truncate(stem, counter + extension);
    }

    /// <summary>Splits at the last dot, but a leading dot is part of the stem (".profile" has no extension), like <c>NSString.pathExtension</c>.</summary>
    internal static (string Stem, string Extension) Split(string name)
    {
        var dot = name.LastIndexOf('.');
        if (dot <= 0 || dot == name.Length - 1)
        {
            return (name, string.Empty);
        }
        return (name[..dot], name[dot..]);
    }

    private static string Truncate(string stem, string suffix)
    {
        var budget = MaxNameLength - suffix.Length;
        if (stem.Length > budget)
        {
            // Cut on a grapheme boundary so a surrogate pair or emoji sequence is never split.
            var info = new StringInfo(stem);
            var count = info.LengthInTextElements;
            while (count > 0 && info.SubstringByTextElements(0, count).Length > budget)
            {
                count--;
            }
            stem = count > 0 ? info.SubstringByTextElements(0, count) : string.Empty;
        }
        stem = stem.TrimEnd(' ', '.');
        if (stem.Length == 0)
        {
            stem = FallbackBaseName;
        }
        return stem + suffix;
    }
}
