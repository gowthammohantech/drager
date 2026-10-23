using System.Text;

namespace SpatialBridge.Core;

/// <summary>
/// Managed Unicode NFC. <c>string.Normalize</c> is a no-op for non-ASCII under InvariantGlobalization,
/// which this solution enables, so filename handling must not depend on ICU.
/// </summary>
internal static partial class UnicodeNfc
{
    private const int SBase = 0xAC00, LBase = 0x1100, VBase = 0x1161, TBase = 0x11A7;
    private const int LCount = 19, VCount = 21, TCount = 28, NCount = VCount * TCount, SCount = LCount * NCount;

    // Built lazily: field initializers in the generated partial file are not ordered relative to these.
    private static readonly Lazy<Dictionary<int, int>> CombiningClassesLazy = new(BuildCcc);
    private static readonly Lazy<Dictionary<int, (int First, int Second)>> DecompositionsLazy = new(BuildDecompositions);
    private static readonly Lazy<Dictionary<long, int>> CompositionsLazy = new(BuildCompositions);

    private static Dictionary<int, int> CombiningClasses => CombiningClassesLazy.Value;
    private static Dictionary<int, (int First, int Second)> Decompositions => DecompositionsLazy.Value;
    private static Dictionary<long, int> Compositions => CompositionsLazy.Value;

    public static string Normalize(string s)
    {
        if (IsAscii(s)) return s;
        var cps = new List<int>(s.Length);
        foreach (var rune in s.EnumerateRunes()) Decompose(rune.Value, cps);
        Reorder(cps);
        Compose(cps);
        var sb = new StringBuilder(s.Length);
        foreach (var cp in cps) sb.Append(char.ConvertFromUtf32(cp));
        return sb.ToString();
    }

    private static bool IsAscii(string s)
    {
        foreach (var c in s)
        {
            if (c > 0x7F) return false;
        }
        return true;
    }

    private static int Ccc(int cp) => CombiningClasses.GetValueOrDefault(cp);

    private static void Decompose(int cp, List<int> output)
    {
        var s = cp - SBase;
        if (s is >= 0 and < SCount)
        {
            output.Add(LBase + (s / NCount));
            output.Add(VBase + (s % NCount / TCount));
            if (s % TCount != 0) output.Add(TBase + (s % TCount));
            return;
        }
        if (Decompositions.TryGetValue(cp, out var d))
        {
            Decompose(d.First, output);
            if (d.Second >= 0) Decompose(d.Second, output);
            return;
        }
        output.Add(cp);
    }

    private static void Reorder(List<int> cps)
    {
        for (var i = 1; i < cps.Count; i++)
        {
            var c = Ccc(cps[i]);
            if (c == 0) continue;
            var j = i;
            while (j > 0 && Ccc(cps[j - 1]) > c)
            {
                (cps[j - 1], cps[j]) = (cps[j], cps[j - 1]);
                j--;
            }
        }
    }

    private static void Compose(List<int> cps)
    {
        if (cps.Count == 0) return;
        var starter = 0;
        var lastClass = Ccc(cps[0]) == 0 ? 0 : 256;
        var write = 1;
        for (var read = 1; read < cps.Count; read++)
        {
            var cp = cps[read];
            var cls = Ccc(cp);
            var blocked = lastClass != 0 && lastClass >= cls;
            if (!blocked && TryCompose(cps[starter], cp, out var composite) && (lastClass < cls || lastClass == 0))
            {
                cps[starter] = composite;
                continue;
            }
            if (cls == 0)
            {
                starter = write;
                lastClass = 0;
            }
            else
            {
                lastClass = cls;
            }
            cps[write++] = cp;
        }
        cps.RemoveRange(write, cps.Count - write);
    }

    private static bool TryCompose(int first, int second, out int composite)
    {
        var l = first - LBase;
        if (l is >= 0 and < LCount)
        {
            var v = second - VBase;
            if (v is >= 0 and < VCount)
            {
                composite = SBase + (((l * VCount) + v) * TCount);
                return true;
            }
        }
        var s = first - SBase;
        if (s is >= 0 and < SCount && s % TCount == 0)
        {
            var t = second - TBase;
            if (t is > 0 and < TCount)
            {
                composite = first + t;
                return true;
            }
        }
        return Compositions.TryGetValue(((long)first << 21) | (uint)second, out composite);
    }

    private static Dictionary<int, int> BuildCcc()
    {
        var map = new Dictionary<int, int>(CombiningClassData.Length / 2);
        for (var i = 0; i < CombiningClassData.Length; i += 2) map[CombiningClassData[i]] = CombiningClassData[i + 1];
        return map;
    }

    private static Dictionary<int, (int, int)> BuildDecompositions()
    {
        var map = new Dictionary<int, (int, int)>(DecompositionData.Length / 3);
        for (var i = 0; i < DecompositionData.Length; i += 3) map[DecompositionData[i]] = (DecompositionData[i + 1], DecompositionData[i + 2]);
        return map;
    }

    private static Dictionary<long, int> BuildCompositions()
    {
        var map = new Dictionary<long, int>(CompositionData.Length / 3);
        for (var i = 0; i < CompositionData.Length; i += 3) map[((long)CompositionData[i] << 21) | (uint)CompositionData[i + 1]] = CompositionData[i + 2];
        return map;
    }
}
