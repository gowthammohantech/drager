using SpatialBridge.Core;
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

public class CollisionNameTests
{
    [Theory]
    [InlineData("photo.jpg", 1, "photo.jpg")]
    [InlineData("photo.jpg", 2, "photo 2.jpg")]
    [InlineData("archive.tar.gz", 3, "archive.tar 3.gz")]
    [InlineData("README", 2, "README 2")]
    [InlineData(".profile", 2, ".profile 2")]
    public void CandidatesMatchSwift(string name, int attempt, string expected)
    {
        Assert.Equal(expected, CollisionNames.Candidate(name, attempt));
    }

    [Fact]
    public void LongNamesStayWithinNtfsLimit()
    {
        var name = new string('a', 251) + ".jpg";
        var candidate = CollisionNames.Candidate(name, 12);
        Assert.Equal(255, candidate.Length);
        Assert.EndsWith(" 12.jpg", candidate, StringComparison.Ordinal);
    }

    [Fact]
    public void TruncationNeverSplitsSurrogates()
    {
        var name = string.Concat(Enumerable.Repeat("\U0001F600", 126)) + ".png"; // 252 + 4 units
        var candidate = CollisionNames.Candidate(name, 2);
        Assert.True(candidate.Length <= 255);
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
        Assert.EndsWith(" 2.png", candidate, StringComparison.Ordinal);
        Assert.Equal(0, (candidate.Length - " 2.png".Length) % 2);
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
