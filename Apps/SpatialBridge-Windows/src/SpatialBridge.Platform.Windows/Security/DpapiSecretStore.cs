using System.Security.Cryptography;
using System.Text;
using SpatialBridge.Platform.Windows.Contracts;

namespace SpatialBridge.Platform.Windows.Security;

/// <summary>
/// Secrets (identity seed, pair PSKs) encrypted with DPAPI, CurrentUser scope, one file per key under
/// <c>%LOCALAPPDATA%\SpatialBridge\Secrets</c>. The entropy binds each blob to its key name, so
/// swapping files between keys fails to decrypt. Values are never logged.
/// </summary>
public sealed class DpapiSecretStore : ISecretStore
{
    /// <summary>Hex doubles the key; 120 UTF-8 bytes keeps the file name well under 255 characters.</summary>
    public const int MaxKeyBytes = 120;

    private const string FileExtension = ".bin";
    private static readonly byte[] EntropyPrefix = "SpatialBridge.DpapiSecretStore.v1\0"u8.ToArray();

    private readonly string _directory;
    private readonly Func<byte[], byte[], byte[]> _protect;
    private readonly Func<byte[], byte[], byte[]> _unprotect;
    private readonly Lock _gate = new();

    public DpapiSecretStore()
        : this(DefaultDirectory())
    {
    }

    public DpapiSecretStore(string directory)
        : this(
            directory,
            static (data, entropy) => ProtectedData.Protect(data, entropy, DataProtectionScope.CurrentUser),
            static (data, entropy) => ProtectedData.Unprotect(data, entropy, DataProtectionScope.CurrentUser))
    {
    }

    /// <summary>Test seam: lets the file layout be exercised on hosts without DPAPI.</summary>
    internal DpapiSecretStore(string directory, Func<byte[], byte[], byte[]> protect, Func<byte[], byte[], byte[]> unprotect)
    {
        _directory = directory;
        _protect = protect;
        _unprotect = unprotect;
    }

    public string Directory => _directory;

    public static string DefaultDirectory() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SpatialBridge", "Secrets");

    public byte[]? Read(string key)
    {
        var path = PathFor(key);
        lock (_gate)
        {
            byte[] blob;
            try
            {
                blob = File.ReadAllBytes(path);
            }
            catch (FileNotFoundException)
            {
                return null;
            }
            catch (DirectoryNotFoundException)
            {
                return null;
            }
            return _unprotect(blob, Entropy(key));
        }
    }

    public void Write(string key, ReadOnlySpan<byte> value)
    {
        var path = PathFor(key);
        var plain = value.ToArray();
        try
        {
            var blob = _protect(plain, Entropy(key));
            lock (_gate)
            {
                System.IO.Directory.CreateDirectory(_directory);
                var temporary = Path.Combine(_directory, $".{Guid.NewGuid():N}.tmp");
                try
                {
                    using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        stream.Write(blob);
                        stream.Flush(flushToDisk: true);
                    }
                    File.Move(temporary, path, overwrite: true);
                }
                finally
                {
                    if (File.Exists(temporary))
                    {
                        File.Delete(temporary);
                    }
                }
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plain);
        }
    }

    public void Delete(string key)
    {
        var path = PathFor(key);
        lock (_gate)
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    public IReadOnlyList<string> Keys(string prefix)
    {
        ArgumentNullException.ThrowIfNull(prefix);
        lock (_gate)
        {
            if (!System.IO.Directory.Exists(_directory))
            {
                return [];
            }
            var keys = new List<string>();
            foreach (var file in System.IO.Directory.EnumerateFiles(_directory, "*" + FileExtension))
            {
                var key = KeyFromFileName(Path.GetFileName(file));
                if (key is not null && key.StartsWith(prefix, StringComparison.Ordinal))
                {
                    keys.Add(key);
                }
            }
            keys.Sort(StringComparer.Ordinal);
            return keys;
        }
    }

    /// <summary>Lowercase hex of the UTF-8 key, so any key maps to a safe, reversible file name.</summary>
    internal static string FileNameFor(string key)
    {
        ArgumentException.ThrowIfNullOrEmpty(key);
        var bytes = Encoding.UTF8.GetBytes(key);
        if (bytes.Length > MaxKeyBytes)
        {
            throw new ArgumentException($"Secret keys are limited to {MaxKeyBytes} UTF-8 bytes.", nameof(key));
        }
        return Convert.ToHexStringLower(bytes) + FileExtension;
    }

    internal static string? KeyFromFileName(string fileName)
    {
        if (!fileName.EndsWith(FileExtension, StringComparison.Ordinal))
        {
            return null;
        }
        var hex = fileName[..^FileExtension.Length];
        if (hex.Length == 0 || hex.Length % 2 != 0)
        {
            return null;
        }
        try
        {
            return Encoding.UTF8.GetString(Convert.FromHexString(hex));
        }
        catch (FormatException)
        {
            return null;
        }
    }

    internal static byte[] Entropy(string key)
    {
        var keyBytes = Encoding.UTF8.GetBytes(key);
        var entropy = new byte[EntropyPrefix.Length + keyBytes.Length];
        EntropyPrefix.CopyTo(entropy, 0);
        keyBytes.CopyTo(entropy, EntropyPrefix.Length);
        return entropy;
    }

    private string PathFor(string key) => Path.Combine(_directory, FileNameFor(key));
}
