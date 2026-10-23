using System.Runtime.InteropServices;
using SpatialBridge.Core;
using SpatialBridge.Platform.Windows.Contracts;
using SpatialBridge.Platform.Windows.Interop;

namespace SpatialBridge.Platform.Windows.Storage;

/// <summary>
/// Windows counterpart of the Mac's <c>renamex_np(RENAME_EXCL)</c> commit (FR-208):
/// <list type="number">
/// <item><c>FlushFileBuffers</c> on the staged file.</item>
/// <item>Mark-of-the-Web on the staged file, so the final name never exists without it.</item>
/// <item><c>MoveFileEx</c> without <c>MOVEFILE_REPLACE_EXISTING</c>: the existence check and the rename are one
/// atomic step; on collision the next candidate is tried.</item>
/// <item>Across volumes the file is first copied to a hidden temporary inside the destination, then moved
/// exclusively, so a partial copy never carries the final name.</item>
/// </list>
/// </summary>
public sealed class WindowsFileCommitter : IFileCommitter
{
    private readonly int _maxAttempts;
    private readonly bool _markOfTheWeb;

    public WindowsFileCommitter(int maxCollisionAttempts = 9999, bool applyMarkOfTheWeb = true)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maxCollisionAttempts, 1);
        _maxAttempts = maxCollisionAttempts;
        _markOfTheWeb = applyMarkOfTheWeb;
    }

    public Task<string> CommitAsync(string stagedPath, string destinationFolder, string saveName, CancellationToken cancellationToken = default) =>
        Task.Run(() => Commit(stagedPath, destinationFolder, saveName), cancellationToken);

    public string Commit(string stagedPath, string destinationFolder, string saveName)
    {
        ArgumentException.ThrowIfNullOrEmpty(stagedPath);
        ArgumentException.ThrowIfNullOrEmpty(destinationFolder);
        if (!IsPlainFileName(saveName))
        {
            throw new BridgeException(BridgeErrorCode.UnsupportedFile, "save name is not a plain file name");
        }
        if (!Directory.Exists(destinationFolder))
        {
            throw new BridgeException(BridgeErrorCode.DestinationPermissionExpired, "destination folder missing");
        }

        var folder = Path.GetFullPath(destinationFolder);
        Flush(stagedPath);
        var marked = _markOfTheWeb && MarkOfTheWeb.TryApply(stagedPath);

        var source = stagedPath;
        string? copiedTemporary = null;
        try
        {
            for (var attempt = 1; attempt <= _maxAttempts; attempt++)
            {
                var candidate = Path.Combine(folder, CollisionNames.Candidate(saveName, attempt));
                EnsureDirectlyInside(candidate, folder);

                if (NativeMethods.MoveFileEx(source, candidate, NativeMethods.MoveFileWriteThrough))
                {
                    copiedTemporary = null;
                    if (_markOfTheWeb && !marked)
                    {
                        MarkOfTheWeb.TryApply(candidate);
                    }
                    return candidate;
                }

                var error = Marshal.GetLastPInvokeError();
                switch (error)
                {
                    case NativeMethods.ErrorFileExists or NativeMethods.ErrorAlreadyExists:
                        continue;
                    case NativeMethods.ErrorNotSameDevice when copiedTemporary is null:
                        copiedTemporary = CopyToTemporary(source, folder);
                        TryDelete(stagedPath);
                        source = copiedTemporary;
                        attempt--; // retry the same candidate from the same-volume temporary
                        continue;
                    default:
                        throw new BridgeException(Classify(error), $"MoveFileEx failed ({error})");
                }
            }
            throw new BridgeException(BridgeErrorCode.WriteFailed, "too many name collisions");
        }
        finally
        {
            if (copiedTemporary is not null)
            {
                TryDelete(copiedTemporary);
            }
        }
    }

    /// <summary>A single path component with no separators, drive or stream syntax.</summary>
    public static bool IsPlainFileName(string? name) =>
        !string.IsNullOrWhiteSpace(name)
        && name is not "." and not ".."
        && name.IndexOfAny(['/', '\\', ':', '\0']) < 0
        && string.Equals(Path.GetFileName(name), name, StringComparison.Ordinal);

    internal static BridgeErrorCode Classify(int win32Error) => win32Error switch
    {
        NativeMethods.ErrorDiskFull or NativeMethods.ErrorHandleDiskFull => BridgeErrorCode.InsufficientStorage,
        NativeMethods.ErrorAccessDenied or NativeMethods.ErrorPathNotFound => BridgeErrorCode.DestinationPermissionExpired,
        _ => BridgeErrorCode.WriteFailed,
    };

    private static void Flush(string path)
    {
        try
        {
            using var handle = File.OpenHandle(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Read);
            if (!NativeMethods.FlushFileBuffers(handle))
            {
                var error = Marshal.GetLastPInvokeError();
                throw new BridgeException(Classify(error), $"FlushFileBuffers failed ({error})");
            }
        }
        catch (IOException error)
        {
            throw new BridgeException(BridgeException.Classify(error, networkContext: false), "staged file unavailable", error);
        }
        catch (UnauthorizedAccessException error)
        {
            throw new BridgeException(BridgeErrorCode.WriteFailed, "staged file unavailable", error);
        }
    }

    private static string CopyToTemporary(string source, string folder)
    {
        var temporary = Path.Combine(folder, $".sb-incoming-{Guid.NewGuid():N}");
        try
        {
            File.Copy(source, temporary, overwrite: false); // CopyFile keeps the Zone.Identifier stream
            Flush(temporary);
            File.SetAttributes(temporary, File.GetAttributes(temporary) | FileAttributes.Hidden);
            return temporary;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            TryDelete(temporary);
            throw new BridgeException(BridgeException.Classify(error, networkContext: false), "cross-volume copy failed", error);
        }
    }

    private static void EnsureDirectlyInside(string candidate, string folder)
    {
        var parent = Path.GetDirectoryName(Path.GetFullPath(candidate));
        if (!string.Equals(Path.TrimEndingDirectorySeparator(parent ?? string.Empty), Path.TrimEndingDirectorySeparator(folder), StringComparison.OrdinalIgnoreCase))
        {
            throw new BridgeException(BridgeErrorCode.UnsupportedFile, "path escapes destination");
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
