using System.Globalization;
using System.Text;

namespace SpatialBridge.Core.Transfer;

/// <summary>Swift-exact port of <c>FilenameSanitizer</c> (the <c>sanitizer</c> vectors are the reference).</summary>
public static class FilenameSanitizer
{
    public const int MaxUtf8Bytes = 255;
    public const string FallbackBaseName = "Received file";

    /// <summary>Longest extension kept, in UTF-8 bytes, after the 16-grapheme cap.</summary>
    public const int MaxExtensionUtf8Bytes = 64;

    /// <summary>A fixed point: <c>Sanitize(Sanitize(x)) == Sanitize(x)</c> and <c>IsSafe(Sanitize(x))</c> for every x.</summary>
    public static string Sanitize(string name, string? contentType = null)
    {
        var parts = name.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries);
        var source = parts.Length > 0 ? parts[^1] : "";

        // Filter before normalizing so removing a control cannot leave a non-NFC sequence.
        var filtered = new StringBuilder(source.Length);
        foreach (var rune in source.EnumerateRunes())
        {
            if (rune.Value < 0x20 || rune.Value == 0x7F || rune.Value == ':') continue;
            filtered.Append(rune.ToString());
        }
        var text = UnicodeNfc.Normalize(filtered.ToString());
        // Trim and strip leading dots until neither changes anything (". .x" must not yield ".x").
        while (true)
        {
            var next = TrimWhitespace(text);
            while (FirstGrapheme(next) == ".") next = next[1..];
            if (next == text) break;
            text = next;
        }
        if (text.Length == 0 || text is "." or "..") text = FallbackBaseName;
        return Finish(text, contentType);
    }

    /// <summary>Splits off and cleans the extension, then caps the length; loops on a strictly shorter base.</summary>
    private static string Finish(string start, string? contentType)
    {
        var text = start;
        while (true)
        {
            var (stem, rawExt) = SplitExtension(text);
            if (stem.Length == 0) stem = FallbackBaseName;
            var ext = CleanExtension(rawExt);
            if (rawExt.Length > 0 && ext.Length == 0)
            {
                // An all-junk extension is dropped with its dot; the stem may hide another one.
                text = TrimTrailingWhitespace(stem);
                continue;
            }
            if (ext.Length == 0 && contentType is not null && UtiCatalog.PreferredExtension(contentType) is { } preferred)
            {
                ext = CleanExtension(preferred);
            }
            var suffix = ext.Length == 0 ? "" : "." + ext;
            var budget = MaxUtf8Bytes - Text.Utf8Length(suffix);
            if (Text.Utf8Length(stem) <= budget) return stem + suffix;
            var trimmed = TrimTrailingWhitespace(TrimToUtf8(stem, budget));
            if (trimmed.Length == 0) trimmed = FallbackBaseName;
            if (ext.Length == 0 && SplitExtension(trimmed).Extension.Length > 0)
            {
                // The cut exposed an extension (it removed the space that hid one).
                text = trimmed;
                contentType = null;
                continue;
            }
            return trimmed + suffix;
        }
    }

    /// <summary>Conservative charset, lowercase, NFC, at most 16 graphemes and <see cref="MaxExtensionUtf8Bytes"/>.</summary>
    private static string CleanExtension(string raw)
    {
        var clean = new StringBuilder(raw.Length);
        foreach (var rune in raw.EnumerateRunes())
        {
            if (IsAlphanumeric(rune) || rune.Value is '-' or '_') clean.Append(rune.ToString());
        }
        // Swift lowercases with full case mapping; U+0130 is the only code point whose full lowercase
        // (i + U+0307) differs from the simple mapping ToLowerInvariant uses.
        var ext = UnicodeNfc.Normalize(clean.ToString().Replace("\u0130", "i\u0307", StringComparison.Ordinal).ToLowerInvariant());
        ext = Text.PrefixGraphemes(ext, 16);
        return TrimToUtf8(ext, MaxExtensionUtf8Bytes);
    }

    private static string TrimTrailingWhitespace(string s)
    {
        var end = s.Length;
        while (end > 0 && Rune.DecodeLastFromUtf16(s.AsSpan(0, end), out var rune, out var used) == System.Buffers.OperationStatus.Done && IsWhitespace(rune)) end -= used;
        return s[..end];
    }

    /// <summary>
    /// <c>IMG.jpeg</c>, attempt 2 → <c>IMG 2.jpeg</c>. The stem is cut first, by grapheme, so <c>stem N.ext</c> fits in
    /// 255 UTF-8 bytes and the counter is always kept (Swift <c>candidate(for:attempt:)</c>).
    /// </summary>
    public static string Candidate(string name, int attempt)
    {
        if (attempt <= 1) return name;
        var (stem, ext) = SplitExtension(name);
        var counter = " " + attempt.ToString(CultureInfo.InvariantCulture);
        var suffix = ext.Length == 0 ? "" : "." + ext;
        var trimmed = TrimToUtf8(stem, MaxUtf8Bytes - Text.Utf8Length(suffix) - Text.Utf8Length(counter));
        if (trimmed.Length == 0) trimmed = FallbackBaseName;
        return Truncate(trimmed + counter, ext);
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
        // NSString only refuses an extension that contains an ASCII space (U+3000 and U+00A0 are kept).
        if (ext.Contains(' ', StringComparison.Ordinal)) return (name, "");
        return (name[..dot], ext);
    }

    private static string Truncate(string stem, string ext)
    {
        var suffix = ext.Length == 0 ? "" : "." + ext;
        var budget = MaxUtf8Bytes - Text.Utf8Length(suffix);
        var trimmed = TrimToUtf8(stem, budget);
        if (trimmed.Length == 0) trimmed = FallbackBaseName;
        return trimmed + suffix;
    }

    /// <summary>Drops whole trailing grapheme clusters until <paramref name="text"/> is at most <paramref name="budget"/> UTF-8 bytes.</summary>
    private static string TrimToUtf8(string text, int budget)
    {
        var length = Text.Utf8Length(text);
        if (length <= budget) return text;
        // Linear: walk the cluster boundaries once and drop whole clusters from the end.
        var boundaries = StringInfo.ParseCombiningCharacters(text);
        var count = boundaries.Length;
        while (count > 0 && length > budget)
        {
            count--;
            length -= Text.Utf8Length(text[boundaries[count]..(count + 1 < boundaries.Length ? boundaries[count + 1] : text.Length)]);
        }
        return count == 0 ? "" : text[..boundaries[count]];
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
