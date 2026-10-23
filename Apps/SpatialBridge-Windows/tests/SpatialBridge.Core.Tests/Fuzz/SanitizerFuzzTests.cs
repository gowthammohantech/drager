using System.Text;
using SpatialBridge.Core.Transfer;
using Xunit.Abstractions;

namespace SpatialBridge.Core.Tests.Fuzz;

/// <summary><c>Sanitize</c> never throws, is idempotent, always yields a name <c>IsSafe</c> accepts, and maps to a valid Windows name.</summary>
public sealed class SanitizerFuzzTests(ITestOutputHelper output)
{
    private static readonly int[][] Pools =
    [
        [.. Enumerable.Range('a', 26), .. Enumerable.Range('A', 26), .. Enumerable.Range('0', 10)],
        [.. ".//\\\\: -_~*?\"<>|".Select(c => (int)c)],
        [.. Enumerable.Range(0, 0x20), 0x7F, 0x85, 0xA0, 0x2028, 0x2029, 0x3000, 0x200B, 0xFEFF, 0x1680],
        [.. Enumerable.Range(0x300, 0x70), 0x20DD, 0x0903, 0x093F],
        [0x00C5, 0x212B, 0x0041, 0x030A, 0x1E9B, 0x0323, 0xFB01, 0x2126, 0x0130, 0x0131, 0x1E9E, 0x00DF],
        [0x1F600, 0x1F468, 0x200D, 0x1F469, 0x1F467, 0x1F3FB, 0xFE0F, 0x1F1FA, 0x1F1F8, 0x1F3F4, 0xE0067, 0xE007F],
        [0x1100, 0x1161, 0x11A8, 0xAC00, 0x4E2D, 0x6587, 0x05D0, 0x0627, 0x202E, 0x202D, 0x0E01, 0x0E33],
        // No lone surrogates: the control-message decoder refuses them (GetString throws), so they never reach Sanitize.
        [0xFFFD, 0xFFFF, 0x10FFFF, 0xE000, 0xF8FF, 0x2160, 0x00B2, 0x0660, 0x2155],
    ];

    private static readonly string?[] ContentTypes = [null, "public.jpeg", "public.png", "com.adobe.pdf", "public.data", "public.plain-text", "x.unknown"];

    private static readonly string[] Prefixes = [".", "..", "../", " .", "./.", "C:\\", "/"];

    private static readonly string[] VectorInputs =
    [
        .. Vectors.File("sanitizer").GetProperty("cases").EnumerateArray().Select(c => c.SOpt("input")).OfType<string>(),
    ];

    private static void AppendRandom(StringBuilder sb, Random rng, int[] pool) => sb.Append(char.ConvertFromUtf32(FuzzRunner.Pick(rng, pool)));

    private static string RandomName(Random rng)
    {
        var sb = new StringBuilder();
        var length = rng.Next(4) switch
        {
            0 => rng.Next(8),
            1 => rng.Next(40),
            2 => 240 + rng.Next(40),
            _ => rng.Next(400),
        };
        var favourite = FuzzRunner.Pick(rng, Pools);
        for (var i = 0; i < length; i++) AppendRandom(sb, rng, rng.Next(3) == 0 ? FuzzRunner.Pick(rng, Pools) : favourite);
        if (rng.Next(3) == 0)
        {
            sb.Append('.');
            var ext = rng.Next(24);
            for (var i = 0; i < ext; i++) AppendRandom(sb, rng, FuzzRunner.Pick(rng, Pools));
        }
        if (rng.Next(6) == 0) sb.Insert(0, FuzzRunner.Pick(rng, Prefixes));
        return sb.ToString();
    }

    private static string Describe(string s) => string.Join(' ', s.EnumerateRunes().Select(r => $"U+{r.Value:X4}"));

    private static void Check(string input, string? contentType)
    {
        try
        {
            CheckProperties(input, contentType);
        }
        catch (Exception e)
        {
            throw new Xunit.Sdk.XunitException($"input [{Describe(input)}] contentType={contentType} -> [{Describe(FilenameSanitizer.Sanitize(input, contentType))}]: {e.Message}");
        }
    }

    private static void CheckProperties(string input, string? contentType)
    {
        var once = FilenameSanitizer.Sanitize(input, contentType);
        Assert.Equal(once, FilenameSanitizer.Sanitize(once));
        Assert.True(FilenameSanitizer.IsSafe(once), "sanitized name is not safe");
        Assert.NotEmpty(once);
        Assert.True(Encoding.UTF8.GetByteCount(once) <= FilenameSanitizer.MaxUtf8Bytes, "too long");
        Assert.DoesNotContain(once, c => c is '/' or '\\' or ':' or < ' ' or '\u007F');
        Assert.NotEqual(".", System.Globalization.StringInfo.GetNextTextElement(once, 0));
        Assert.Equal(once, Text.Nfc(once));
        if (FilenameSanitizer.IsSafe(input)) Assert.True(Text.CanonicallyEqual(input, FilenameSanitizer.Sanitize(input)));
        WindowsSaveNameTests.AssertValidWindowsName(WindowsSaveName.Map(once));
    }

    [Fact]
    public void RandomUnicodeNames() =>
        FuzzRunner.Run("sanitizer-random", (rng, _) => Check(RandomName(rng), FuzzRunner.Pick(rng, ContentTypes)), log: output.WriteLine);

    [Fact]
    public void MutatedVectorNames() => FuzzRunner.Run("sanitizer-mutate", (rng, _) =>
    {
        var name = new StringBuilder(FuzzRunner.Pick(rng, VectorInputs));
        var rounds = 1 + rng.Next(3);
        for (var r = 0; r < rounds; r++)
        {
            var at = rng.Next(name.Length + 1);
            switch (rng.Next(3))
            {
                case 0: name.Insert(at, char.ConvertFromUtf32(FuzzRunner.Pick(rng, FuzzRunner.Pick(rng, Pools)))); break;
                case 1 when at < name.Length: name.Remove(at, 1); break;
                default: name.Length = Math.Min(name.Length, at); break;
            }
        }
        // Deleting one UTF-16 unit can split a surrogate pair; such strings cannot come off the wire.
        var text = name.ToString();
        if (!IsWellFormed(text)) return;
        Check(text, FuzzRunner.Pick(rng, ContentTypes));
    }, log: output.WriteLine);

    private static bool IsWellFormed(string s)
    {
        for (var i = 0; i < s.Length; i++)
        {
            if (char.IsHighSurrogate(s[i]) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1])) i++;
            else if (char.IsSurrogate(s[i])) return false;
        }
        return true;
    }

    [Fact]
    public void LongNamesFinishInBoundedTime()
    {
        // A 64 KiB control frame can carry a ~60k-character filename; truncation must stay linear.
        FuzzRunner.Run("sanitizer-long", (rng, _) =>
        {
            var sb = new StringBuilder();
            var pool = FuzzRunner.Pick(rng, Pools);
            while (sb.Length < 60_000) AppendRandom(sb, rng, pool);
            Check(sb.ToString(), null);
        }, count: Math.Max(10, FuzzRunner.Iterations / 200), log: output.WriteLine);
    }
}
