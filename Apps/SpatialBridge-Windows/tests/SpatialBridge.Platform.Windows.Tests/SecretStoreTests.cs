using System.Security.Cryptography;
using SpatialBridge.Platform.Windows.Security;

namespace SpatialBridge.Platform.Windows.Tests;

public class DpapiSecretStoreTests
{
    // Reversible stand-in for DPAPI that still checks the entropy is passed through.
    private static DpapiSecretStore FakeStore(string directory) => new(
        directory,
        static (data, entropy) => [.. SHA256.HashData(entropy), .. data.Select(b => (byte)(b ^ 0x5A))],
        static (blob, entropy) =>
        {
            if (!blob.AsSpan(0, 32).SequenceEqual(SHA256.HashData(entropy)))
            {
                throw new CryptographicException("entropy mismatch");
            }
            return [.. blob.Skip(32).Select(b => (byte)(b ^ 0x5A))];
        });

    [Fact]
    public void FileNamesAreReversibleHex()
    {
        Assert.Equal("70736b3a616263.bin", DpapiSecretStore.FileNameFor("psk:abc"));
        Assert.Equal("psk:abc", DpapiSecretStore.KeyFromFileName("70736b3a616263.bin"));
        Assert.Null(DpapiSecretStore.KeyFromFileName("zz.bin"));
        Assert.Null(DpapiSecretStore.KeyFromFileName("abc.txt"));
        Assert.Throws<ArgumentException>(() => DpapiSecretStore.FileNameFor(new string('k', 121)));
    }

    [Fact]
    public void EntropyBindsKeyName()
    {
        Assert.NotEqual(DpapiSecretStore.Entropy("a"), DpapiSecretStore.Entropy("b"));
    }

    [Fact]
    public void RoundTripsAndListsByPrefix()
    {
        using var dir = new TempDirectory();
        var store = FakeStore(dir.Path);
        store.Write("psk:peer1", [1, 2, 3]);
        store.Write("psk:peer2", [4]);
        store.Write("identity.seed", [9, 9]);

        Assert.Equal([1, 2, 3], store.Read("psk:peer1"));
        Assert.Equal(["psk:peer1", "psk:peer2"], store.Keys("psk:"));
        Assert.Null(store.Read("missing"));

        store.Write("psk:peer1", [7]);
        Assert.Equal([7], store.Read("psk:peer1"));

        store.Delete("psk:peer1");
        store.Delete("psk:peer1");
        Assert.Null(store.Read("psk:peer1"));
        Assert.Equal(["psk:peer2"], store.Keys("psk:"));
    }

    [Fact]
    public void BlobsDoNotContainPlaintextAndCannotBeSwapped()
    {
        using var dir = new TempDirectory();
        var store = FakeStore(dir.Path);
        store.Write("a", "secret-value"u8);
        store.Write("b", "other"u8);
        var aPath = Path.Combine(dir.Path, DpapiSecretStore.FileNameFor("a"));
        var bPath = Path.Combine(dir.Path, DpapiSecretStore.FileNameFor("b"));
        Assert.DoesNotContain("secret-value", File.ReadAllText(aPath), StringComparison.Ordinal);

        File.Copy(aPath, bPath, overwrite: true);
        Assert.Throws<CryptographicException>(() => store.Read("b"));
    }

    [Fact]
    public void ListingAnEmptyStoreIsEmpty()
    {
        var store = FakeStore(Path.Combine(Path.GetTempPath(), "sb-none-" + Guid.NewGuid().ToString("N")));
        Assert.Empty(store.Keys(string.Empty));
    }

    [WindowsFact]
    public void RealDpapiRoundTrip()
    {
        using var dir = new TempDirectory();
        var store = new DpapiSecretStore(dir.Path);
        store.Write("psk:peer", [1, 2, 3, 4]);
        Assert.Equal([1, 2, 3, 4], store.Read("psk:peer"));
        Assert.NotEqual([1, 2, 3, 4], File.ReadAllBytes(Path.Combine(dir.Path, DpapiSecretStore.FileNameFor("psk:peer"))));
    }
}
