using System.Collections.Frozen;
using System.Text;

namespace SpatialBridge.Core.Transfer;

/// <summary>
/// Apple's UTI declarations as exported from macOS (<c>UtiCatalog.Data.g.cs</c>): identifier → preferred extension
/// and full supertype set, plus extension → identifier as <c>UTType(filenameExtension:)</c> resolves it. This lets
/// Windows apply the Mac's conformance checks without UniformTypeIdentifiers.
/// </summary>
public static partial class UtiCatalog
{
    private sealed record Entry(string? Extension, FrozenSet<string> Supertypes);

    private static readonly Lazy<FrozenDictionary<string, Entry>> ById = new(() =>
    {
        var map = new Dictionary<string, Entry>(StringComparer.Ordinal);
        foreach (var line in GeneratedData.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var f = line.Split('|');
            map[f[0]] = new Entry(f[1].Length == 0 ? null : f[1], f[3].Split(' ', StringSplitOptions.RemoveEmptyEntries).ToFrozenSet(StringComparer.Ordinal));
        }
        return map.ToFrozenDictionary(StringComparer.Ordinal);
    });

    private static readonly Lazy<FrozenDictionary<string, string>> ByExtension = new(() =>
        GeneratedExtensions.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(l => l.Split('|'))
            .ToFrozenDictionary(f => f[0], f => f[1], StringComparer.OrdinalIgnoreCase));

    public static int Count => ById.Value.Count;

    public static bool IsDynamic(string uti) => uti.StartsWith("dyn.", StringComparison.Ordinal);

    public static bool IsKnown(string uti) => ById.Value.ContainsKey(uti);

    public static string? TypeForExtension(string extension) => ByExtension.Value.GetValueOrDefault(extension);

    /// <summary>True if <paramref name="uti"/> is, or conforms to, <paramref name="parent"/>.</summary>
    public static bool ConformsTo(string uti, string parent) =>
        string.Equals(uti, parent, StringComparison.Ordinal) || (ById.Value.TryGetValue(uti, out var e) && e.Supertypes.Contains(parent));

    /// <summary>UTType.preferredFilenameExtension, including the <c>1=</c> tag of a dynamic type.</summary>
    public static string? PreferredExtension(string uti)
    {
        if (ById.Value.TryGetValue(uti, out var entry)) return entry.Extension;
        if (IsDynamic(uti) && DecodeDynamic(uti) is { } decoded)
        {
            foreach (var part in decoded.TrimStart('?').Split(':'))
            {
                if (part.StartsWith("1=", StringComparison.Ordinal)) return part[2..];
            }
        }
        return null;
    }

    /// <summary>Decodes <c>dyn.a…</c> (Apple's base-32 with alphabet <c>abcdefghkmnpqrstuvwxyz0123456789</c>).</summary>
    public static string? DecodeDynamic(string uti)
    {
        const string alphabet = "abcdefghkmnpqrstuvwxyz0123456789";
        if (!uti.StartsWith("dyn.a", StringComparison.Ordinal)) return null;
        var bytes = new List<byte>();
        int buffer = 0, bits = 0;
        foreach (var c in uti.AsSpan(5))
        {
            var v = alphabet.IndexOf(c, StringComparison.Ordinal);
            if (v < 0) return null;
            buffer = (buffer << 5) | v;
            bits += 5;
            if (bits >= 8)
            {
                bits -= 8;
                bytes.Add((byte)((buffer >> bits) & 0xFF));
            }
        }
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes.ToArray());
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }
}
