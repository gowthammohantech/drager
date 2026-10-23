using System.Text.Json;
using SpatialBridge.Core.Json;
using SpatialBridge.Core.Pairing;

namespace SpatialBridge.Core.Services;

public sealed class InMemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, byte[]> _values = new(StringComparer.Ordinal);
    private readonly Lock _gate = new();

    public byte[]? Read(string key)
    {
        lock (_gate) { return _values.TryGetValue(key, out var v) ? (byte[])v.Clone() : null; }
    }

    public void Write(string key, ReadOnlySpan<byte> value)
    {
        lock (_gate) { _values[key] = value.ToArray(); }
    }

    public void Delete(string key)
    {
        lock (_gate) { _values.Remove(key); }
    }

    public IReadOnlyList<string> Keys(string prefix)
    {
        lock (_gate) { return [.. _values.Keys.Where(k => k.StartsWith(prefix, StringComparison.Ordinal)).Order(StringComparer.Ordinal)]; }
    }
}

/// <summary>
/// <c>secrets.json</c> with base64 values. <b>Unencrypted: test and CLI use only.</b> The Windows app uses a DPAPI store.
/// </summary>
public sealed class FileSecretStore(string path) : ISecretStore
{
    private readonly Lock _gate = new();

    public byte[]? Read(string key)
    {
        lock (_gate) { return Load().TryGetValue(key, out var v) ? Convert.FromBase64String(v) : null; }
    }

    public void Write(string key, ReadOnlySpan<byte> value)
    {
        lock (_gate)
        {
            var all = Load();
            all[key] = Convert.ToBase64String(value);
            Save(all);
        }
    }

    public void Delete(string key)
    {
        lock (_gate)
        {
            var all = Load();
            if (all.Remove(key)) Save(all);
        }
    }

    public IReadOnlyList<string> Keys(string prefix)
    {
        lock (_gate) { return [.. Load().Keys.Where(k => k.StartsWith(prefix, StringComparison.Ordinal)).Order(StringComparer.Ordinal)]; }
    }

    private Dictionary<string, string> Load()
    {
        if (!File.Exists(path)) return new(StringComparer.Ordinal);
        return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllBytes(path)) is { } d ? new(d, StringComparer.Ordinal) : new(StringComparer.Ordinal);
    }

    private void Save(Dictionary<string, string> values)
    {
        var obj = new JsonObject();
        foreach (var (k, v) in values) obj.Add(k, v);
        AtomicFile.Write(path, CanonicalJson.Encode(obj), ownerOnly: true);
    }
}

public sealed class InMemoryTrustedPeerStore : ITrustedPeerStore
{
    private readonly Dictionary<string, TrustedPeer> _peers = new(StringComparer.Ordinal);
    private readonly Lock _gate = new();

    public IReadOnlyList<TrustedPeer> All()
    {
        lock (_gate) { return [.. _peers.Values.OrderBy(p => p.PairedAt)]; }
    }

    public TrustedPeer? Find(string peerID)
    {
        lock (_gate) { return _peers.GetValueOrDefault(peerID); }
    }

    public void Upsert(TrustedPeer peer)
    {
        lock (_gate) { _peers[peer.PeerID] = peer; }
    }

    public void Remove(string peerID)
    {
        lock (_gate) { _peers.Remove(peerID); }
    }
}

/// <summary><c>trusted-peers.json</c>: public metadata only (no secrets), written atomically.</summary>
public sealed class FileTrustedPeerStore(string path) : ITrustedPeerStore
{
    private readonly Lock _gate = new();

    public IReadOnlyList<TrustedPeer> All()
    {
        lock (_gate) { return [.. Load().OrderBy(p => p.PairedAt)]; }
    }

    public TrustedPeer? Find(string peerID)
    {
        lock (_gate) { return Load().FirstOrDefault(p => p.PeerID == peerID); }
    }

    public void Upsert(TrustedPeer peer)
    {
        lock (_gate)
        {
            var all = Load().Where(p => p.PeerID != peer.PeerID).Append(peer).ToList();
            Save(all);
        }
    }

    public void Remove(string peerID)
    {
        lock (_gate) { Save([.. Load().Where(p => p.PeerID != peerID)]); }
    }

    private List<TrustedPeer> Load()
    {
        if (!File.Exists(path)) return [];
        using var doc = JsonDocument.Parse(File.ReadAllBytes(path));
        return [.. doc.RootElement.EnumerateArray().Select(e => new TrustedPeer(
            e.GetProperty("peerID").GetString()!,
            e.GetProperty("displayName").GetString()!,
            new DevicePlatform(e.GetProperty("platform").GetString()!),
            e.GetProperty("model").GetString()!,
            Convert.FromBase64String(e.GetProperty("signingPublicKey").GetString()!),
            DateTimeOffset.FromUnixTimeMilliseconds(e.GetProperty("pairedAt").GetInt64()),
            e.TryGetProperty("lastSeenAt", out var seen) && seen.ValueKind == JsonValueKind.Number ? DateTimeOffset.FromUnixTimeMilliseconds(seen.GetInt64()) : null))];
    }

    private void Save(List<TrustedPeer> peers)
    {
        var items = peers.Select(p => new JsonObject()
            .Add("peerID", p.PeerID)
            .Add("displayName", p.DisplayName)
            .Add("platform", p.Platform.Raw)
            .Add("model", p.Model)
            .Add("signingPublicKey", p.SigningPublicKey)
            .Add("pairedAt", p.PairedAt.ToUnixTimeMilliseconds())
            .Add("lastSeenAt", p.LastSeenAt?.ToUnixTimeMilliseconds())).ToList();
        AtomicFile.Write(path, CanonicalJson.Encode(items), ownerOnly: false);
    }
}

internal static class AtomicFile
{
    public static void Write(string path, byte[] bytes, bool ownerOnly)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(dir);
        var temp = Path.Combine(dir, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write };
        if (ownerOnly && !OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        using (var stream = new FileStream(temp, options))
        {
            stream.Write(bytes);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temp, path, overwrite: true);
    }
}
