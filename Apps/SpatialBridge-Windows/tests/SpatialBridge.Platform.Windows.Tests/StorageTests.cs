using SpatialBridge.Core;
using SpatialBridge.Core.Transfer;
using SpatialBridge.Platform.Windows.Storage;

namespace SpatialBridge.Platform.Windows.Tests;

public class MarkOfTheWebTests
{
    [Fact]
    public void ContentIsInternetZone()
    {
        Assert.Equal("[ZoneTransfer]\r\nZoneId=3\r\n", MarkOfTheWeb.Content);
        Assert.Equal("[ZoneTransfer]\r\nZoneId=3\r\n"u8.ToArray(), MarkOfTheWeb.ContentBytes());
        Assert.Equal(3, MarkOfTheWeb.ParseZoneId(MarkOfTheWeb.Content));
    }

    [Fact]
    public void StreamPathAppendsAlternateStream()
    {
        Assert.Equal(@"C:\Users\me\Downloads\a.jpg:Zone.Identifier", MarkOfTheWeb.StreamPath(@"C:\Users\me\Downloads\a.jpg"));
    }

    [Fact]
    public void ParseZoneIdHandlesOtherSectionsAndMissingValue()
    {
        Assert.Equal(-1, MarkOfTheWeb.ParseZoneId("[Other]\r\nZoneId=3\r\n"));
        Assert.Equal(2, MarkOfTheWeb.ParseZoneId("[ZoneTransfer]\nHostUrl=about:internet\nZoneId=2\n"));
        Assert.Equal(-1, MarkOfTheWeb.ParseZoneId(string.Empty));
    }

    [WindowsFact]
    public void AppliesOnNtfs()
    {
        using var dir = new TempDirectory();
        var file = dir.File("a.txt");
        Assert.True(MarkOfTheWeb.TryApply(file));
        Assert.True(MarkOfTheWeb.IsApplied(file));
        Assert.Equal(MarkOfTheWeb.Content, File.ReadAllText(MarkOfTheWeb.StreamPath(file)));
    }
}

/// <summary>
/// The Windows committer delegates candidate naming to Core's <see cref="FileCommit.CommitWithCollisions"/>; these run
/// that loop with an in-memory "volume" so the naming contract is checked on every host.
/// </summary>
public class CollisionNameTests
{
    private static string CommitInto(HashSet<string> existing, string saveName)
    {
        var folder = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "sb-collisions"));
        var final = FileCommit.CommitWithCollisions("staged", folder, saveName, (_, candidate) => existing.Add(Path.GetFileName(candidate)));
        Assert.Equal(folder, Path.GetDirectoryName(final));
        return Path.GetFileName(final);
    }

    [Theory]
    [InlineData("photo.jpg", 1, "photo.jpg")]
    [InlineData("photo.jpg", 2, "photo 2.jpg")]
    [InlineData("archive.tar.gz", 3, "archive.tar 3.gz")]
    [InlineData("README", 2, "README 2")]
    [InlineData(".profile", 2, ".profile 2")]
    public void CandidatesMatchSwift(string name, int attempt, string expected)
    {
        Assert.Equal(expected, FilenameSanitizer.Candidate(name, attempt));
        var existing = new HashSet<string>(StringComparer.Ordinal);
        for (var taken = 1; taken < attempt; taken++)
        {
            existing.Add(FilenameSanitizer.Candidate(name, taken));
        }
        Assert.Equal(expected, CommitInto(existing, name));
    }

    [Fact]
    public void ReservedNamesAreMappedForEveryCandidate()
    {
        Assert.Equal("CON_.txt", CommitInto([], "CON.txt"));
        Assert.Equal("NUL_", CommitInto([], "NUL"));
        // FolderDestination hands the committer the mapped name, so collisions keep the suffix.
        var saveName = WindowsSaveName.Map(FilenameSanitizer.Sanitize("CON.txt"));
        Assert.Equal("CON_.txt", saveName);
        Assert.Equal("CON_ 2.txt", CommitInto(new HashSet<string>(StringComparer.Ordinal) { "CON_.txt" }, saveName));
    }

    [Fact]
    public void CandidatesStayWithinTheUtf8Limit()
    {
        var name = new string('a', 240) + ".jpg";
        var candidate = FilenameSanitizer.Candidate(name, 12);
        Assert.Equal(new string('a', 240) + " 12.jpg", candidate);
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(candidate) <= FilenameSanitizer.MaxUtf8Bytes);
    }

    [Fact]
    public void TruncationNeverSplitsSurrogates()
    {
        var name = string.Concat(Enumerable.Repeat("\U0001F600", 62)) + ".png"; // 248 + 4 UTF-8 bytes
        var candidate = FilenameSanitizer.Candidate(name, 20);
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(candidate) <= FilenameSanitizer.MaxUtf8Bytes);
        for (var i = 0; i < candidate.Length; i++)
        {
            if (char.IsHighSurrogate(candidate[i]))
            {
                Assert.True(i + 1 < candidate.Length && char.IsLowSurrogate(candidate[++i]));
            }
            else
            {
                Assert.False(char.IsLowSurrogate(candidate[i]));
            }
        }
        Assert.EndsWith(".png", candidate, StringComparison.Ordinal);
    }

    [Fact]
    public void GivesUpAfterTheAttemptLimit()
    {
        var error = Assert.Throws<BridgeException>(() => FileCommit.CommitWithCollisions("staged", Path.GetTempPath(), "a.txt", (_, _) => false, maxAttempts: 3));
        Assert.Equal(BridgeErrorCode.WriteFailed, error.Code);
    }
}

public class WindowsFileCommitterTests
{
    [Theory]
    [InlineData("a.jpg", true)]
    [InlineData("..", false)]
    [InlineData("a/b.jpg", false)]
    [InlineData(@"a\b.jpg", false)]
    [InlineData("a.jpg:evil", false)]
    [InlineData("C:x.jpg", false)]
    [InlineData(" ", false)]
    public void PlainFileNames(string name, bool expected)
    {
        Assert.Equal(expected, WindowsFileCommitter.IsPlainFileName(name));
    }

    [Fact]
    public void Win32ErrorsMapToWireCodes()
    {
        Assert.Equal(BridgeErrorCode.InsufficientStorage, WindowsFileCommitter.Classify(112));
        Assert.Equal(BridgeErrorCode.InsufficientStorage, WindowsFileCommitter.Classify(39));
        Assert.Equal(BridgeErrorCode.DestinationPermissionExpired, WindowsFileCommitter.Classify(5));
        Assert.Equal(BridgeErrorCode.WriteFailed, WindowsFileCommitter.Classify(1117));
    }

    [Fact]
    public void RejectsPathLikeSaveNamesOnAnyHost()
    {
        using var dir = new TempDirectory();
        var staged = dir.File("staged");
        var error = Assert.Throws<BridgeException>(() => new WindowsFileCommitter().Commit(staged, dir.Path, "../escape.txt"));
        Assert.Equal(BridgeErrorCode.UnsupportedFile, error.Code);
    }

    [WindowsFact]
    public void CommitsExclusivelyWithCollisionRenameAndMotw()
    {
        using var dir = new TempDirectory();
        var destination = Directory.CreateDirectory(Path.Combine(dir.Path, "dest")).FullName;
        File.WriteAllText(Path.Combine(destination, "photo.jpg"), "existing");
        var staged = dir.File("staged.part", "new");

        var final = new WindowsFileCommitter().Commit(staged, destination, "photo.jpg");

        Assert.Equal(Path.Combine(destination, "photo 2.jpg"), final);
        Assert.Equal("existing", File.ReadAllText(Path.Combine(destination, "photo.jpg")));
        Assert.Equal("new", File.ReadAllText(final));
        Assert.False(File.Exists(staged));
        Assert.True(MarkOfTheWeb.IsApplied(final));
    }

    [WindowsFact]
    public async Task MissingDestinationIsPermissionExpired()
    {
        using var dir = new TempDirectory();
        var staged = dir.File("staged.part");
        var error = await Assert.ThrowsAsync<BridgeException>(() => new WindowsFileCommitter().CommitAsync(staged, Path.Combine(dir.Path, "gone"), "a.txt"));
        Assert.Equal(BridgeErrorCode.DestinationPermissionExpired, error.Code);
    }
}
