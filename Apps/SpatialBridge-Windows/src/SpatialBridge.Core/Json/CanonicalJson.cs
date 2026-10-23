using System.Globalization;
using System.Text;

namespace SpatialBridge.Core.Json;

/// <summary>
/// A JSON object whose keys serialize in Unicode code point order (CONFORMANCE.md §1).
/// Values: string, bool, int/long/uint/ulong, double, byte[] (base64), Guid (uppercase), JsonObject, IEnumerable of values.
/// A null value omits the key.
/// </summary>
public sealed class JsonObject : IEnumerable<KeyValuePair<string, object?>>
{
    private readonly SortedDictionary<string, object?> _entries = new(CodePointComparer.Instance);

    public JsonObject Add(string key, object? value)
    {
        _entries[key] = value;
        return this;
    }

    public object? this[string key]
    {
        get => _entries.TryGetValue(key, out var v) ? v : null;
        set => _entries[key] = value;
    }

    public IEnumerator<KeyValuePair<string, object?>> GetEnumerator() => _entries.GetEnumerator();

    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();

    private sealed class CodePointComparer : IComparer<string>
    {
        public static readonly CodePointComparer Instance = new();

        public int Compare(string? x, string? y)
        {
            if (ReferenceEquals(x, y)) return 0;
            if (x is null) return -1;
            if (y is null) return 1;
            var a = x.EnumerateRunes().GetEnumerator();
            var b = y.EnumerateRunes().GetEnumerator();
            while (true)
            {
                var hasA = a.MoveNext();
                var hasB = b.MoveNext();
                if (!hasA || !hasB) return hasA == hasB ? 0 : hasA ? 1 : -1;
                var c = a.Current.Value.CompareTo(b.Current.Value);
                if (c != 0) return c;
            }
        }
    }
}

/// <summary>Writes canonical JSON byte-for-byte like Swift's JSONEncoder with <c>.sortedKeys, .withoutEscapingSlashes</c>.</summary>
public static class CanonicalJson
{
    public static byte[] Encode(object value) => Encoding.UTF8.GetBytes(EncodeToString(value));

    public static string EncodeToString(object value)
    {
        var sb = new StringBuilder(256);
        WriteValue(sb, value);
        return sb.ToString();
    }

    private static void WriteValue(StringBuilder sb, object value)
    {
        switch (value)
        {
            case string s: WriteString(sb, s); break;
            case bool b: sb.Append(b ? "true" : "false"); break;
            case int i: sb.Append(i.ToString(CultureInfo.InvariantCulture)); break;
            case long l: sb.Append(l.ToString(CultureInfo.InvariantCulture)); break;
            case uint u: sb.Append(u.ToString(CultureInfo.InvariantCulture)); break;
            case ulong ul: sb.Append(ul.ToString(CultureInfo.InvariantCulture)); break;
            case double d: sb.Append(FormatDouble(d)); break;
            case byte[] data: sb.Append('"').Append(Convert.ToBase64String(data)).Append('"'); break;
            case Guid g: sb.Append('"').Append(g.ToString("D").ToUpperInvariant()).Append('"'); break;
            case JsonObject obj:
                sb.Append('{');
                var first = true;
                foreach (var (key, v) in obj)
                {
                    if (v is null) continue;
                    if (!first) sb.Append(',');
                    first = false;
                    WriteString(sb, key);
                    sb.Append(':');
                    WriteValue(sb, v);
                }
                sb.Append('}');
                break;
            case System.Collections.IEnumerable list:
                sb.Append('[');
                var firstItem = true;
                foreach (var item in list)
                {
                    if (!firstItem) sb.Append(',');
                    firstItem = false;
                    if (item is null) sb.Append("null"); else WriteValue(sb, item);
                }
                sb.Append(']');
                break;
            default:
                throw new ArgumentException($"Unsupported JSON value type {value.GetType().Name}", nameof(value));
        }
    }

    /// <summary>Escapes exactly <c>"</c>, <c>\</c> and C0 controls; everything else, including <c>/</c> and non-ASCII, is raw.</summary>
    public static void WriteString(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case < ' ': sb.Append("\\u00").Append(((int)c).ToString("x2", CultureInfo.InvariantCulture)); break;
                default: sb.Append(c); break;
            }
        }
        sb.Append('"');
    }

    /// <summary>Swift's <c>Double.description</c> minus a trailing <c>.0</c>: shortest round-trip digits, exponent form below 1e-4 or from 1e16.</summary>
    public static string FormatDouble(double d)
    {
        if (double.IsNaN(d) || double.IsInfinity(d)) throw new ArgumentException("Non-finite double", nameof(d));
        if (d == 0) return double.IsNegative(d) ? "-0" : "0";
        var shortest = Math.Abs(d).ToString("R", CultureInfo.InvariantCulture);
        var digits = new StringBuilder();
        var exponent = 0;
        var e = shortest.IndexOfAny(['E', 'e']);
        var mantissa = e < 0 ? shortest : shortest[..e];
        if (e >= 0) exponent = int.Parse(shortest.AsSpan(e + 1), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
        var dot = mantissa.IndexOf('.', StringComparison.Ordinal);
        var intPart = dot < 0 ? mantissa : mantissa[..dot];
        var fracPart = dot < 0 ? "" : mantissa[(dot + 1)..];
        digits.Append(intPart).Append(fracPart);
        // value = 0.digits × 10^(pointPos)
        var pointPos = intPart.Length + exponent;
        var all = digits.ToString();
        var lead = 0;
        while (lead < all.Length - 1 && all[lead] == '0') { lead++; pointPos--; }
        all = all[lead..].TrimEnd('0');
        if (all.Length == 0) all = "0";
        var sci = pointPos - 1;
        var sign = d < 0 ? "-" : "";
        if (sci < -4 || sci >= 16)
        {
            var m = all.Length == 1 ? all : $"{all[0]}.{all[1..]}";
            return $"{sign}{m}e{(sci < 0 ? "-" : "+")}{Math.Abs(sci):00}";
        }
        if (pointPos <= 0) return $"{sign}0.{new string('0', -pointPos)}{all}";
        if (pointPos >= all.Length) return sign + all + new string('0', pointPos - all.Length);
        return $"{sign}{all[..pointPos]}.{all[pointPos..]}";
    }
}
