using System.Globalization;
using System.Text;

namespace SpatialBridge.Core.Transfer;

/// <summary>Swift-exact port of <c>FilenameSanitizer</c> (the <c>sanitizer</c> vectors are the reference).</summary>
public static class FilenameSanitizer
{
    public const int MaxUtf8Bytes = 255;
    public const string FallbackBaseName = "Received file";

    public static string Sanitize(string name, string? contentType = null)
    {
        var parts = name.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        var source = parts.Length > 0 ? parts[^1] : "";
        source = UnicodeNfc.Normalize(source);

        var filtered = new StringBuilder(source.Length);
        foreach (var rune in source.EnumerateRunes())
        {
            if (rune.Value < 0x20 || rune.Value == 0x7F || rune.Value == ':') continue;
            filtered.Append(rune.ToString());
        }
        var text = TrimWhitespace(filtered.ToString());
        while (FirstGrapheme(text) == ".") text = text[1..];
        text = TrimWhitespace(text);
        if (text.Length == 0 || text is "." or "..") text = FallbackBaseName;

        var (stem, ext) = SplitExtension(text);
        if (stem.Length == 0) stem = FallbackBaseName;
        if (ext.Length == 0 && contentType is not null && UtiCatalog.PreferredExtension(contentType) is { } preferred)
        {
            ext = preferred;
        }
        var cleanExt = new StringBuilder(ext.Length);
        foreach (var rune in ext.EnumerateRunes())
        {
            if (IsAlphanumeric(rune) || rune.Value is '-' or '_') cleanExt.Append(rune.ToString());
        }
        ext = cleanExt.ToString().ToLowerInvariant();
        ext = Text.PrefixGraphemes(ext, 16);
        return Truncate(stem, ext);
    }

    /// <summary><c>IMG.jpeg</c>, attempt 2 → <c>IMG 2.jpeg</c>.</summary>
    public static string Candidate(string name, int attempt)
    {
        if (attempt <= 1) return name;
        var (stem, ext) = SplitExtension(name);
        return Truncate($"{stem} {attempt.ToString(CultureInfo.InvariantCulture)}", ext);
    }

    /// <summary>True if <paramref name="name"/> is exactly what <see cref="Sanitize"/> produces (Swift compares canonically).</summary>
    public static bool IsSafe(string name) =>
        Text.CanonicallyEqual(Sanitize(name), name) && !name.Contains('/', StringComparison.Ordinal) && !name.Contains('\\', StringComparison.Ordinal);

    /// <summary>NSString <c>deletingPathExtension</c> / <c>pathExtension</c> for a single component.</summary>
    public static (string Stem, string Extension) SplitExtension(string name)
    {
        var dot = name.LastIndexOf('.');
        if (dot <= 0 || dot == name.Length - 1) return (name, "");
        var ext = name[(dot + 1)..];
        if (ext.Any(char.IsWhiteSpace)) return (name, "");
        return (name[..dot], ext);
    }

    private static string Truncate(string stem, string ext)
    {
        var suffix = ext.Length == 0 ? "" : "." + ext;
        var budget = MaxUtf8Bytes - Text.Utf8Length(suffix);
        var trimmed = stem;
        if (Text.Utf8Length(trimmed) > budget)
        {
            var info = new StringInfo(trimmed);
            var count = info.LengthInTextElements;
            while (count > 0 && Text.Utf8Length(info.SubstringByTextElements(0, count)) > budget) count--;
            trimmed = count == 0 ? "" : info.SubstringByTextElements(0, count);
        }
        if (trimmed.Length == 0) trimmed = FallbackBaseName;
        return trimmed + suffix;
    }

    private static string? FirstGrapheme(string s) => s.Length == 0 ? null : StringInfo.GetNextTextElement(s, 0);

    /// <summary>Foundation's <c>whitespacesAndNewlines</c>: Z*, U+0009–U+000D and U+0085.</summary>
    public static bool IsWhitespace(Rune r) =>
        r.Value is (>= 0x09 and <= 0x0D) or 0x85 ||
        Rune.GetUnicodeCategory(r) is UnicodeCategory.SpaceSeparator or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator;

    private static string TrimWhitespace(string s)
    {
        var runes = s.EnumerateRunes().ToList();
        var start = 0;
        var end = runes.Count;
        while (start < end && IsWhitespace(runes[start])) start++;
        while (end > start && IsWhitespace(runes[end - 1])) end--;
        var sb = new StringBuilder(s.Length);
        for (var i = start; i < end; i++) sb.Append(runes[i].ToString());
        return sb.ToString();
    }

    /// <summary>Foundation's <c>alphanumerics</c>: L*, M* and N*.</summary>
    private static bool IsAlphanumeric(Rune r) => Rune.GetUnicodeCategory(r) switch
    {
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
            or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
            or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark
            or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber => true,
        _ => false,
    };
}

/// <summary>
/// Maps a name that passed <see cref="FilenameSanitizer.IsSafe"/> to a valid Windows file name (ADR-015):
/// <c>&lt;&gt;:"/\|?*</c> become <c>_</c>, trailing dots and spaces are trimmed, and reserved device names get a <c>_</c> suffix.
/// </summary>
public static class WindowsSaveName
{
    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
        "COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³",
        "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³",
    };

    public static string Map(string name)
    {
        var sb = new StringBuilder(name.Length);
        foreach (var c in name)
        {
            sb.Append(c is '<' or '>' or ':' or '"' or '/' or '\\' or '|' or '?' or '*' || c < ' ' ? '_' : c);
        }
        var mapped = sb.ToString().TrimEnd('.', ' ');
        if (mapped.Length == 0) return FilenameSanitizer.FallbackBaseName;

        var firstDot = mapped.IndexOf('.');
        var device = (firstDot < 0 ? mapped : mapped[..firstDot]).TrimEnd(' ');
        if (Reserved.Contains(device))
        {
            mapped = firstDot < 0 ? mapped + "_" : string.Concat(mapped.AsSpan(0, firstDot), "_", mapped.AsSpan(firstDot));
        }
        return mapped;
    }

    public static bool IsReserved(string name)
    {
        var firstDot = name.IndexOf('.');
        return Reserved.Contains((firstDot < 0 ? name : name[..firstDot]).TrimEnd(' '));
    }
}
