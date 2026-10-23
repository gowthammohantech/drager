using System.Text;
using SpatialBridge.Core.Messages;
using Xunit.Abstractions;

namespace SpatialBridge.Core.Tests.Fuzz;

/// <summary>
/// Mutates the golden <c>control-messages</c> vectors. <see cref="ControlMessageCoder.Decode(ReadOnlySpan{byte})"/> must
/// return a message whose canonical re-encoding is stable, or throw <see cref="BridgeException"/> E012; nothing else.
/// </summary>
public sealed class ControlMessageFuzzTests(ITestOutputHelper output)
{
    private static readonly byte[][] Seeds =
    [
        .. Vectors.File("control-messages").GetProperty("cases").EnumerateArray().SelectMany(c =>
        {
            var list = new List<byte[]> { c.H("hex") };
            if (c.SOpt("inputJson") is { } input) list.Add(Encoding.UTF8.GetBytes(input));
            return list;
        }),
    ];

    private static readonly byte[][] InvalidUtf8 =
    [
        [0xC0, 0x80], [0xFF], [0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82],
    ];

    private static readonly string[] HugeNumbers =
    [
        "1e999999999", "-1e-999999999", "1e309", "-1e309", "99999999999999999999999999999", "18446744073709551616",
        "9223372036854775808", "-9223372036854775809", "4294967296", "2147483648", "-1", "1.5", "1.0", "1E+2", "-0",
        "0.0000001", "1" + new string('0', 5000), "0." + new string('0', 5000) + "1", "1e-2147483649", "NaN", "Infinity", "0x10", "01",
    ];

    private static readonly string[] Escapes = ["\\ud800", "\\udc00", "\\udc00\\ud800", "\\u0000", "\\uZZZZ", "\\", "\\x", "\"", "\\u12"];

    private const string Punctuation = "\"\\{}[],:0-e.n ";

    private static byte[] Splice(byte[] input, int at, int remove, ReadOnlySpan<byte> insert)
    {
        at = Math.Clamp(at, 0, input.Length);
        remove = Math.Clamp(remove, 0, input.Length - at);
        return [.. input.AsSpan(0, at), .. insert, .. input.AsSpan(at + remove)];
    }

    private static byte[] DeepNesting(Random rng)
    {
        var depth = FuzzRunner.Pick(rng, [15, 16, 17, 64, 200, 1_000, 10_000, 30_000]);
        var (open, close) = rng.Next(2) == 0 ? ("[", "]") : ("{\"a\":", "}");
        var inner = string.Concat(Enumerable.Repeat(open, depth)) + "1" + string.Concat(Enumerable.Repeat(close, rng.Next(4) == 0 ? depth / 2 : depth));
        return Encoding.UTF8.GetBytes(rng.Next(3) switch
        {
            0 => inner,
            1 => $"{{\"body\":{inner},\"kind\":\"PING\"}}",
            _ => $"{{\"body\":{{\"sentAt\":1,\"sequence\":{inner}}},\"kind\":\"PING\"}}",
        });
    }

    private static bool IsDigit(byte b) => b is >= (byte)'0' and <= (byte)'9';

    private static byte[] ReplaceNumber(Random rng, byte[] input)
    {
        var digits = Enumerable.Range(0, input.Length).Where(i => IsDigit(input[i])).ToList();
        if (digits.Count == 0) return input;
        var start = FuzzRunner.Pick(rng, digits);
        while (start > 0 && (IsDigit(input[start - 1]) || input[start - 1] == '-')) start--;
        var end = start;
        while (end < input.Length && "0123456789.eE+-".Contains((char)input[end], StringComparison.Ordinal)) end++;
        return Splice(input, start, end - start, Encoding.UTF8.GetBytes(FuzzRunner.Pick(rng, HugeNumbers)));
    }

    private static byte[] Mutate(Random rng, byte[] seed)
    {
        var b = seed;
        var rounds = 1 + rng.Next(4);
        for (var r = 0; r < rounds; r++)
        {
            switch (rng.Next(11))
            {
                case 0 when b.Length > 0:
                    b = (byte[])b.Clone();
                    b[rng.Next(b.Length)] ^= (byte)(1 << rng.Next(8));
                    break;
                case 1: b = Splice(b, rng.Next(b.Length + 1), 0, [(byte)rng.Next(256)]); break;
                case 2 when b.Length > 0: b = Splice(b, rng.Next(b.Length), 1 + rng.Next(8), []); break;
                case 3: b = b[..rng.Next(b.Length + 1)]; break;
                case 4: b = Splice(b, rng.Next(b.Length + 1), 0, FuzzRunner.Pick(rng, InvalidUtf8)); break;
                case 5: b = ReplaceNumber(rng, b); break;
                case 6: b = DeepNesting(rng); break;
                case 7 when b.Length > 0:
                    {
                        var i = rng.Next(b.Length);
                        b = Splice(b, i, 0, b.AsSpan(i, Math.Min(b.Length - i, 1 + rng.Next(64))));
                        break;
                    }
                case 8 when b.Length > 0: b = Splice(b, rng.Next(b.Length), 1, [(byte)Punctuation[rng.Next(Punctuation.Length)]]); break;
                case 9:
                    {
                        var quotes = Enumerable.Range(0, b.Length).Where(i => b[i] == '"').ToList();
                        if (quotes.Count > 0) b = Splice(b, FuzzRunner.Pick(rng, quotes) + 1, 0, Encoding.UTF8.GetBytes(FuzzRunner.Pick(rng, Escapes)));
                        break;
                    }
                case 10: b = FuzzRunner.Pick(rng, Seeds); break;
                default: break;
            }
        }
        return b;
    }

    private static void CheckDecode(byte[] input)
    {
        ControlMessage message;
        try
        {
            message = ControlMessageCoder.Decode(input);
        }
        catch (BridgeException e)
        {
            Assert.Equal(BridgeErrorCode.ProtocolMismatch, e.Code);
            return;
        }
        byte[] canonical;
        try
        {
            canonical = ControlMessageCoder.Encode(message);
        }
        catch (Exception e) when (e is ArgumentException or FormatException)
        {
            throw new Xunit.Sdk.XunitException($"decoded {message.Kind} cannot be re-encoded: {e}");
        }
        Assert.Equal(canonical, ControlMessageCoder.Encode(ControlMessageCoder.Decode(canonical)));
    }

    [Fact]
    public void MutatedGoldenVectorsDecodeOrFailE012() =>
        FuzzRunner.Run("control-json-mutate", (rng, _) => CheckDecode(Mutate(rng, FuzzRunner.Pick(rng, Seeds))), log: output.WriteLine);

    [Fact]
    public void RandomBytesDecodeOrFailE012() => FuzzRunner.Run("control-json-random", (rng, _) =>
    {
        const string Alphabet = "{}[]\",:0123456789.eE-truefalsn\\u ";
        var input = rng.Next(2) == 0
            ? FuzzRunner.Bytes(rng, 256)
            : [.. Enumerable.Range(0, rng.Next(256)).Select(_ => (byte)Alphabet[rng.Next(Alphabet.Length)])];
        CheckDecode(input);
    }, log: output.WriteLine);

    private const string OfferWithGesture =
        "{\"body\":{\"byteCount\":10485760,\"contentType\":\"public.jpeg\",\"createdAt\":1760000000123,\"filename\":\"IMG_0001.jpeg\"," +
        "\"gesture\":{\"edge\":\"top\",\"firedAt\":1760000000123,\"normalizedPosition\":NP,\"outwardVelocity\":812.5,\"travelDistance\":143.25}," +
        "\"protocolVersion\":1,\"sha256Hex\":\"0000000000000000000000000000000000000000000000000000000000000000\"," +
        "\"sourcePeerID\":\"65b60673d6ed884bf01c2c222d82ada0\",\"targetPeerID\":\"ba8112fa4ba3d6f934b2ad2aa0696602\"," +
        "\"transferID\":\"3F2504E0-4F89-41D3-9A0C-0305E82C3301\"},\"kind\":\"TRANSFER_OFFER\"}";

    private static void AssertRejected(string json)
    {
        var e = Assert.Throws<BridgeException>(() => ControlMessageCoder.Decode(Encoding.UTF8.GetBytes(json)));
        Assert.Equal(BridgeErrorCode.ProtocolMismatch, e.Code);
    }

    [Fact]
    public void NumbersOutsideTheJsonGrammarOrTheTargetTypeAreRejected()
    {
        ControlMessageCoder.Decode(Encoding.UTF8.GetBytes(OfferWithGesture.Replace("NP", "0.42", StringComparison.Ordinal)));
        foreach (var token in new[] { "1e309", "-1e309", "1e999999999", "NaN", "Infinity", "-Infinity", "1f", "1d", "0x1p3", "+1", ".5", "1.", "01", "-", "1e", "\"0.42\"" })
        {
            AssertRejected(OfferWithGesture.Replace("NP", token, StringComparison.Ordinal));
        }
        foreach (var token in new[] { "4294967296", "-1", "1e999999999", "18446744073709551616", "NaN", "1f", "+1", "01", "0x10" })
        {
            AssertRejected($"{{\"body\":{{\"sentAt\":1,\"sequence\":{token}}},\"kind\":\"PING\"}}");
        }
        AssertRejected("{\"body\":{\"code\":\"E005\",\"message\":\"\\ud800\"},\"kind\":\"ERROR\"}");
    }

    [Fact]
    public void DeepNestingAndHugeNumbersFailE012InBoundedTime()
    {
        FuzzRunner.Run("control-json-extremes", (rng, _) => CheckDecode(DeepNesting(rng)), count: Math.Max(50, FuzzRunner.Iterations / 20), log: output.WriteLine);
        foreach (var n in HugeNumbers)
        {
            CheckDecode(Encoding.UTF8.GetBytes($"{{\"body\":{{\"sentAt\":{n},\"sequence\":1}},\"kind\":\"PING\"}}"));
            CheckDecode(Encoding.UTF8.GetBytes($"{{\"body\":{{\"sentAt\":1,\"sequence\":{n}}},\"kind\":\"PONG\"}}"));
            CheckDecode(Encoding.UTF8.GetBytes($"{{\"body\":{{\"acknowledgedOffset\":{n},\"transferID\":\"6BA7B810-9DAD-11D1-80B4-00C04FD430C8\"}},\"kind\":\"PROGRESS\"}}"));
        }
        // Oversized payloads are refused before parsing.
        AssertRejected("{\"body\":{\"code\":\"E005\",\"message\":\"" + new string('a', ControlMessageCoder.MaxPayloadBytes) + "\"},\"kind\":\"ERROR\"}");
    }
}
