using System.Security.Cryptography;

namespace SpatialBridge.Core.Transfer;

/// <summary>
/// Durably moves a fully verified staged file into the destination (Swift <c>DestinationStore.commit</c>).
/// Portable: <see cref="PortableFileCommitter"/>. Windows (Lane WU): MoveFileEx + FlushFileBuffers + Mark-of-the-Web,
/// ideally built on <see cref="FileCommit.CommitWithCollisions"/>.
/// </summary>
public interface IFileCommitter
{
    /// <summary>
    /// Moves <paramref name="stagedPath"/> into <paramref name="destinationFolder"/> as <paramref name="saveName"/>
    /// (already a valid Windows save name), adding " 2", " 3"… on collision. Never overwrites. Returns the final full path.
    /// Throws <see cref="BridgeException"/>.
    /// </summary>
    Task<string> CommitAsync(string stagedPath, string destinationFolder, string saveName, CancellationToken cancellationToken = default);
}

public static class FileCommit
{
    /// <summary>
    /// Tries <c>saveName</c>, then <c>stem 2.ext</c>, <c>stem 3.ext</c>… via <paramref name="tryMove"/>, which must
    /// atomically rename without overwriting and return false only when the target already exists.
    /// </summary>
    public static string CommitWithCollisions(string stagedPath, string destinationFolder, string saveName, Func<string, string, bool> tryMove, int maxAttempts = 9999)
    {
        var folder = Path.GetFullPath(destinationFolder).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            var candidateName = WindowsSaveName.Map(FilenameSanitizer.Candidate(saveName, attempt));
            var candidate = Path.GetFullPath(Path.Combine(folder, candidateName));
            if (!string.Equals(Path.GetDirectoryName(candidate), folder, StringComparison.Ordinal))
            {
                throw new BridgeException(BridgeErrorCode.UnsupportedFile, "path escapes destination");
            }
            try
            {
                if (tryMove(stagedPath, candidate)) return candidate;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                throw new BridgeException(BridgeException.Classify(ex, false), "commit failed", ex);
            }
        }
        throw new BridgeException(BridgeErrorCode.WriteFailed, "too many name collisions");
    }
}

/// <summary><c>File.Move(overwrite: false)</c>: MoveFileEx without REPLACE_EXISTING on Windows, link+unlink on Unix.</summary>
public sealed class PortableFileCommitter : IFileCommitter
{
    public Task<string> CommitAsync(string stagedPath, string destinationFolder, string saveName, CancellationToken cancellationToken = default) =>
        Task.FromResult(FileCommit.CommitWithCollisions(stagedPath, destinationFolder, saveName, TryMove));

    public static bool TryMove(string stagedPath, string finalPath)
    {
        try
        {
            File.Move(stagedPath, finalPath, overwrite: false);
            return true;
        }
        catch (IOException) when (File.Exists(finalPath) || Directory.Exists(finalPath))
        {
            return false;
        }
    }
}

/// <summary>
/// Staging directory for partial downloads (FR-206). It sits inside the destination folder so the final
/// rename stays on one volume. Files are <c>&lt;UUID&gt;.sbpart</c> and are removed on any failure.
/// </summary>
public sealed class StagingArea
{
    public const string PartialExtension = ".sbpart";
    public const string DefaultFolderName = ".spatialbridge-staging";

    public StagingArea(string directory)
    {
        Directory = directory;
        System.IO.Directory.CreateDirectory(directory);
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        else
        {
            // The leading dot hides it on Unix; Explorer needs the attribute (re-applied if the folder was recreated).
            try
            {
                var info = new DirectoryInfo(directory);
                if (!info.Attributes.HasFlag(FileAttributes.Hidden)) info.Attributes |= FileAttributes.Hidden;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    public string Directory { get; }

    public static StagingArea In(string destinationFolder) => new(Path.Combine(destinationFolder, DefaultFolderName));

    public string PathFor(Guid transferID) => Path.Combine(Directory, Uuids.ToWire(transferID) + PartialExtension);

    public StagedFileWriter CreateWriter(Guid transferID, long expectedBytes) => new(PathFor(transferID), expectedBytes);

    public void Remove(Guid transferID)
    {
        try { File.Delete(PathFor(transferID)); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public IEnumerable<string> PartialFiles() =>
        System.IO.Directory.Exists(Directory) ? System.IO.Directory.EnumerateFiles(Directory, "*" + PartialExtension) : [];

    /// <summary>Deletes partial files older than <paramref name="age"/>.</summary>
    public int Purge(TimeSpan age, DateTimeOffset? now = null)
    {
        var cutoff = (now ?? DateTimeOffset.UtcNow) - age;
        var removed = 0;
        foreach (var file in PartialFiles().ToList())
        {
            try
            {
                if (File.GetLastWriteTimeUtc(file) <= cutoff.UtcDateTime)
                {
                    File.Delete(file);
                    removed++;
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return removed;
    }
}

/// <summary>Sequential writer for one staged file with incremental SHA-256.</summary>
public sealed class StagedFileWriter : IDisposable
{
    private readonly FileStream _stream;
    private readonly IncrementalHash _hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    private bool _closed;

    internal StagedFileWriter(string path, long expectedBytes)
    {
        Path = path;
        ExpectedBytes = expectedBytes;
        try { File.Delete(path); } catch (IOException) { }
        var options = new FileStreamOptions
        {
            Mode = FileMode.CreateNew,
            Access = FileAccess.Write,
            Share = FileShare.None,
            BufferSize = 0,
        };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        try
        {
            _stream = new FileStream(path, options);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new BridgeException(BridgeException.Classify(ex, false), "cannot create staging file", ex);
        }
    }

    public string Path { get; }
    public long ExpectedBytes { get; }
    public long BytesWritten { get; private set; }

    public async Task AppendAsync(ReadOnlyMemory<byte> data, CancellationToken ct = default)
    {
        if (BytesWritten + data.Length > ExpectedBytes) throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "more bytes than offered");
        try
        {
            await _stream.WriteAsync(data, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new BridgeException(BridgeException.Classify(ex, false), "staging write failed", ex);
        }
        _hash.AppendData(data.Span);
        BytesWritten += data.Length;
    }

    /// <summary>Flushes to stable storage (fsync) and closes. Returns the lowercase hex digest.</summary>
    public string Finish()
    {
        try
        {
            _stream.Flush(flushToDisk: true);
            _stream.Dispose();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new BridgeException(BridgeException.Classify(ex, false), "fsync failed", ex);
        }
        _closed = true;
        return Hex.Encode(_hash.GetHashAndReset());
    }

    public void Abandon()
    {
        Dispose();
        try { File.Delete(Path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        if (!_closed)
        {
            _closed = true;
            try { _stream.Dispose(); } catch (IOException) { }
        }
        _hash.Dispose();
    }
}

/// <summary>Terminal outcomes by transfer ID so a replay never creates a second file. Bounded; oldest evicted.</summary>
public sealed class TransferOutcomeLedger(int capacity = 1000)
{
    private readonly Dictionary<Guid, TransferOutcome> _outcomes = [];
    private readonly Queue<Guid> _order = new();
    private readonly Lock _gate = new();

    public TransferOutcome? Outcome(Guid id)
    {
        lock (_gate) { return _outcomes.GetValueOrDefault(id); }
    }

    public void Record(Guid id, TransferOutcome outcome)
    {
        lock (_gate)
        {
            if (_outcomes.TryAdd(id, outcome))
            {
                _order.Enqueue(id);
                if (_order.Count > capacity) _outcomes.Remove(_order.Dequeue());
            }
            else
            {
                _outcomes[id] = outcome;
            }
        }
    }
}

public abstract record TransferOutcome
{
    private TransferOutcome() { }

    public sealed record Committed(string SavedFilename, long ByteCount) : TransferOutcome;

    public sealed record Failed(BridgeErrorCode Code) : TransferOutcome;
}

/// <summary>A destination folder: access and free-space checks plus a never-overwriting commit (FR-208).</summary>
public sealed class FolderDestination(string folder, IFileCommitter? committer = null, Func<string, long>? freeSpace = null)
{
    private readonly IFileCommitter _committer = committer ?? new PortableFileCommitter();

    public string Folder { get; } = Path.GetFullPath(folder);

    public void ValidateAccess()
    {
        if (!Directory.Exists(Folder)) throw new BridgeException(BridgeErrorCode.DestinationPermissionExpired, "destination missing");
        try
        {
            var probe = Path.Combine(Folder, $".sb-probe-{Guid.NewGuid():N}");
            using (File.Create(probe, 1, FileOptions.DeleteOnClose)) { }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new BridgeException(BridgeErrorCode.DestinationPermissionExpired, "destination not writable", ex);
        }
    }

    public long AvailableCapacity()
    {
        if (freeSpace is not null) return freeSpace(Folder);
        try
        {
            return new DriveInfo(Folder).AvailableFreeSpace;
        }
        catch (Exception ex) when (ex is IOException or ArgumentException or UnauthorizedAccessException)
        {
            return long.MaxValue;
        }
    }

    /// <summary>Sanitizes and maps the offered name to a Windows save name, then commits. Returns the final path.</summary>
    public Task<string> CommitAsync(string stagedFile, string suggestedName, CancellationToken ct = default) =>
        _committer.CommitAsync(stagedFile, Folder, WindowsSaveName.Map(FilenameSanitizer.Sanitize(suggestedName)), ct);
}
