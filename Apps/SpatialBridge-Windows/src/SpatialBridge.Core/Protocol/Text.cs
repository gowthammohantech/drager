using System.Globalization;
using System.Text;

namespace SpatialBridge.Core;

/// <summary>String helpers that follow Swift's Character (extended grapheme cluster) semantics.</summary>
public static class Text
{
    public static int GraphemeCount(string s) => new StringInfo(s).LengthInTextElements;

    public static string PrefixGraphemes(string s, int count)
    {
        var info = new StringInfo(s);
        return info.LengthInTextElements <= count ? s : info.SubstringByTextElements(0, count);
    }

    /// <summary>NFC that works under InvariantGlobalization.</summary>
    public static string Nfc(string s) => UnicodeNfc.Normalize(s);

    public static int Utf8Length(string s) => Encoding.UTF8.GetByteCount(s);

    /// <summary>Swift String equality: canonical equivalence.</summary>
    public static bool CanonicallyEqual(string a, string b) =>
        string.Equals(UnicodeNfc.Normalize(a), UnicodeNfc.Normalize(b), StringComparison.Ordinal);
}
