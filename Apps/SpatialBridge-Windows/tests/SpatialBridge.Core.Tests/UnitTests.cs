using System.Text;

using SpatialBridge.Core.Json;
using SpatialBridge.Core.Messages;
using SpatialBridge.Core.Pairing;
using SpatialBridge.Core.Transfer;

namespace SpatialBridge.Core.Tests;

public sealed class WindowsSaveNameTests
{
    internal static void AssertValidWindowsName(string name)
    {
        Assert.False(string.IsNullOrEmpty(name));
        Assert.DoesNotContain(name, c => c is '<' or '>' or ':' or '"' or '/' or '\\' or '|' or '?' or '*' || c < ' ');
        Assert.False(name.EndsWith('.') || name.EndsWith(' '), name);
        Assert.False(WindowsSaveName.IsReserved(name), name);
    }

    [Theory]
    [InlineData("CON.txt", "CON_.txt")]
    [InlineData("con", "con_")]
    [InlineData("NUL", "NUL_")]
    [InlineData("PRN.doc", "PRN_.doc")]
    [InlineData("AUX", "AUX_")]
    [InlineData("COM1.txt", "COM1_.txt")]
    [InlineData("lpt9", "lpt9_")]
    [InlineData("CONIN$", "CONIN$_")]
    [InlineData("con.tar.gz", "con_.tar.gz")]
    [InlineData("a<b>.txt", "a_b_.txt")]
    [InlineData("what?.txt", "what_.txt")]
    [InlineData("star*.txt", "star_.txt")]
    [InlineData("pipe|.txt", "pipe_.txt")]
    [InlineData("quote\".txt", "quote_.txt")]
    [InlineData("file.", "file")]
    [InlineData("file...", "file")]
    [InlineData("name. . ", "name")]
    [InlineData("...", "Received file")]
    [InlineData("COM10.txt", "COM10.txt")]
    [InlineData("CONSOLE.txt", "CONSOLE.txt")]
    [InlineData("IMG_0001.jpeg", "IMG_0001.jpeg")]
    [InlineData("Résumé 📄.pdf", "Résumé 📄.pdf")]
    public void Maps(string input, string expected)
    {
        Assert.Equal(expected, WindowsSaveName.Map(input));
        AssertValidWindowsName(WindowsSaveName.Map(input));
    }

    [Fact]
    public void TrailingDotCannotSmuggleDeniedExtension()
    {
        // "x.exe." passes isSafe and has no Swift extension, but Windows would save it as x.exe.
        Assert.True(FilenameSanitizer.IsSafe("x.exe."));
        var ex = Assert.Throws<BridgeException>(() => TransferPolicy.Default.ValidateName("x.exe.", "public.data"));
        Assert.Equal(BridgeErrorCode.UnsupportedFile, ex.Code);
    }
}

public sealed class TransferPolicyTests
{
    [Theory]
    [InlineData("a.exe")]
    [InlineData("a.msi")]
    [InlineData("a.bat")]
    [InlineData("a.cmd")]
    [InlineData("a.com")]
    [InlineData("a.scr")]
    [InlineData("a.ps1")]
    [InlineData("a.psm1")]
    [InlineData("a.vbs")]
    [InlineData("a.vbe")]
    [InlineData("a.js")]
    [InlineData("a.jse")]
    [InlineData("a.wsf")]
    [InlineData("a.wsh")]
    [InlineData("a.lnk")]
    [InlineData("a.hta")]
    [InlineData("a.cpl")]
    [InlineData("a.msc")]
    [InlineData("a.reg")]
    [InlineData("a.jar")]
    [InlineData("a.appx")]
    [InlineData("a.msix")]
    [InlineData("a.msixbundle")]
    [InlineData("a.appinstaller")]
    [InlineData("a.sh")]
    [InlineData("a.command")]
    [InlineData("a.app")]
    [InlineData("a.pkg")]
    [InlineData("a.dmg")]
    [InlineData("a.py")]
    [InlineData("a.scpt")]
    [InlineData("a.iso")]
    [InlineData("a.url")]
    [InlineData("‮gnp.exe")]
    public void DeniesWindowsExecutablesAsData(string filename)
    {
        var ex = Assert.Throws<BridgeException>(() => TransferPolicy.Default.ValidateName(filename, "public.data"));
        Assert.Equal(BridgeErrorCode.UnsupportedFile, ex.Code);
    }

    [Theory]
    [InlineData("a.exe", "com.microsoft.windows-executable")]
    [InlineData("a.bin", "public.executable")]
    [InlineData("a", "public.unix-executable")]
    [InlineData("a.txt", "public.shell-script")]
    public void DeniesByType(string filename, string uti) =>
        Assert.Equal(BridgeErrorCode.UnsupportedFile, Assert.Throws<BridgeException>(() => TransferPolicy.Default.ValidateName(filename, uti)).Code);

    [Theory]
    [InlineData("a.jpg", "public.jpeg")]
    [InlineData("a.xyz", "dyn.ah62d4rv4ge80e5pe")]
    [InlineData("a.bin", "public.data")]
    [InlineData("a.docx", "org.openxmlformats.wordprocessingml.document")]
    [InlineData("IMG_0001.heic", "public.heic")]
    [InlineData("rand.bin", "com.apple.macbinary-archive")]
    [InlineData("Deck.key", "com.apple.iwork.keynote.sffkey")]
    [InlineData("a.usdz", "com.pixar.universal-scene-description-mobile")]
    public void AllowsData(string filename, string uti) => TransferPolicy.Default.ValidateName(filename, uti);

    [Fact]
    public void CatalogIsTheMacDatabase()
    {
        Assert.True(UtiCatalog.Count > 500);
        Assert.True(UtiCatalog.ConformsTo("public.python-script", "public.shell-script"));
        Assert.True(UtiCatalog.ConformsTo("com.apple.application-bundle", "com.apple.application"));
        Assert.Equal("public.shell-script", UtiCatalog.TypeForExtension("SH"));
        Assert.Equal("jpeg", UtiCatalog.PreferredExtension("public.jpeg"));
    }

    [Fact]
    public void UnknownTypesFollowConfiguration()
    {
        Assert.Throws<BridgeException>(() => TransferPolicy.Default.ValidateName("a.xyz", "com.example.unknown"));
        new TransferPolicy { AcceptUnknownTypes = true }.ValidateName("a.xyz", "com.example.unknown");
        Assert.Throws<BridgeException>(() => new TransferPolicy { AcceptUnknownTypes = true }.ValidateName("a.exe", "com.example.unknown"));
    }

    [Fact]
    public void OfferChecksRunInSwiftOrder()
    {
        var offer = new TransferOffer(2, Guid.NewGuid(), "a", "b", "../x", "bogus", 0, "zz", null, 0);
        Assert.Equal(BridgeErrorCode.ProtocolMismatch, Assert.Throws<BridgeException>(() => TransferPolicy.Default.Validate(offer)).Code);
        offer = offer with { ProtocolVersion = 1 };
        Assert.Equal(BridgeErrorCode.UnsupportedFile, Assert.Throws<BridgeException>(() => TransferPolicy.Default.Validate(offer)).Code);
        offer = offer with { ByteCount = (100L << 20) + 1 };
        Assert.Equal(BridgeErrorCode.SizeLimit, Assert.Throws<BridgeException>(() => TransferPolicy.Default.Validate(offer)).Code);
        offer = offer with { ByteCount = 1 };
        Assert.Equal(BridgeErrorCode.ProtocolMismatch, Assert.Throws<BridgeException>(() => TransferPolicy.Default.Validate(offer)).Code);
        offer = offer with { Sha256Hex = new string('a', 64) };
        Assert.Equal(BridgeErrorCode.UnsupportedFile, Assert.Throws<BridgeException>(() => TransferPolicy.Default.Validate(offer)).Code);
    }
}

public sealed class CanonicalJsonTests
{
    [Theory]
    [InlineData(0.42, "0.42")]
    [InlineData(812.5, "812.5")]
    [InlineData(1500.0, "1500")]
    [InlineData(0.0001, "0.0001")]
    [InlineData(1e-05, "1e-05")]
    [InlineData(1e15, "1000000000000000")]
    [InlineData(1e16, "1e+16")]
    [InlineData(-2.5, "-2.5")]
    public void DoublesMatchSwift(double value, string expected) => Assert.Equal(expected, CanonicalJson.FormatDouble(value));

    [Fact]
    public void KeysSortedNullsOmitted()
    {
        var json = CanonicalJson.EncodeToString(new JsonObject().Add("b", 1).Add("a", null).Add("A", "x/y").Add("é", true));
        Assert.Equal("{\"A\":\"x/y\",\"b\":1,\"é\":true}", json);
    }

    [Fact]
    public void RejectsOversizedAndMalformed()
    {
        Assert.Throws<BridgeException>(() => ControlMessageCoder.Decode(new byte[65537]));
        Assert.Throws<BridgeException>(() => ControlMessageCoder.Decode("{\"kind\":\"NOPE\",\"body\":{}}"u8));
        Assert.Throws<BridgeException>(() => ControlMessageCoder.Decode("{\"kind\":\"PING\",\"body\":{\"sequence\":1}}"u8));
        Assert.Throws<BridgeException>(() => ControlMessageCoder.Decode("{\"kind\":\"ERROR\",\"body\":{\"code\":\"E015\"}}"u8));
        Assert.Throws<BridgeException>(() => ControlMessageCoder.Decode(Encoding.UTF8.GetBytes("{\"kind\":\"SESSION_AUTH\",\"body\":{\"signature\":\"AA\"}}")));
    }
}

public sealed class RateLimiterTests
{
    [Fact]
    public void ThreeFailuresLockForSixtySeconds()
    {
        var time = new ManualTime(DateTimeOffset.UnixEpoch);
        var limiter = new PairingRateLimiter(time: time);
        limiter.RecordFailure("p");
        limiter.RecordFailure("p");
        Assert.False(limiter.IsLocked("p"));
        limiter.RecordFailure("p");
        Assert.True(limiter.IsLocked("p"));
        Assert.False(limiter.IsLocked("q"));
        time.Advance(TimeSpan.FromSeconds(59));
        Assert.True(limiter.IsLocked("p"));
        time.Advance(TimeSpan.FromSeconds(1));
        Assert.False(limiter.IsLocked("p"));
        limiter.RecordFailure("p");
        limiter.RecordSuccess("p");
        limiter.RecordFailure("p");
        limiter.RecordFailure("p");
        Assert.False(limiter.IsLocked("p"));
    }
}

public sealed class LedgerTests
{
    [Fact]
    public void EvictsOldest()
    {
        var ledger = new TransferOutcomeLedger(2);
        var ids = Enumerable.Range(0, 3).Select(_ => Guid.NewGuid()).ToArray();
        foreach (var id in ids) ledger.Record(id, new TransferOutcome.Failed(BridgeErrorCode.Timeout));
        Assert.Null(ledger.Outcome(ids[0]));
        Assert.NotNull(ledger.Outcome(ids[2]));
        ledger.Record(ids[2], new TransferOutcome.Committed("a", 1));
        Assert.IsType<TransferOutcome.Committed>(ledger.Outcome(ids[2]));
    }
}
