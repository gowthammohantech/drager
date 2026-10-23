namespace SpatialBridge.App.Services;

/// <summary>
/// Log-safe forms of user data, matching Swift <c>Redaction</c> (AGENTS.md: never log file contents,
/// pairing secrets or raw filenames).
/// </summary>
internal static class Redaction
{
    /// <summary><c>***.jpg (a1b2c3)</c>: the extension and a stable FNV-1a hash, never the name.</summary>
    public static string Filename(string name)
    {
        var extension = Path.GetExtension(name).TrimStart('.');
        var hash = StableHash(name);
        return extension.Length == 0 ? $"*** ({hash})" : $"***.{extension} ({hash})";
    }

    public static string FilePath(string path) => "…\\" + Filename(Path.GetFileName(path));

    /// <summary>First 8 characters of a peer ID, enough to correlate.</summary>
    public static string Peer(string peerID) => peerID.Length <= 8 ? peerID : peerID[..8] + "…";

    public static string Transfer(Guid id) => id.ToString("D")[..8].ToUpperInvariant();

    /// <summary>6-hex-digit FNV-1a over UTF-8, identical to Swift <c>Redaction.stableHash</c>.</summary>
    public static string StableHash(string value)
    {
        var hash = 2_166_136_261u;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(value))
        {
            hash ^= b;
            hash = unchecked(hash * 16_777_619u);
        }
        return (hash & 0xFFFFFF).ToString("x6", System.Globalization.CultureInfo.InvariantCulture);
    }
}
