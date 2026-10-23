using System.Text.Json;

namespace SpatialBridge.Core.Tests;

/// <summary>Reads Conformance/vectors/*.json in place. Cases are addressed by name so each one is its own test.</summary>
internal static class Vectors
{
    private static readonly Dictionary<string, JsonDocument> Cache = [];
    private static readonly Lock Gate = new();

    public static JsonElement File(string kind)
    {
        lock (Gate)
        {
            if (!Cache.TryGetValue(kind, out var doc))
            {
                var path = RepoPaths.Vectors(kind + ".json");
                if (!System.IO.File.Exists(path)) throw new FileNotFoundException($"Vector file missing: {path}");
                doc = JsonDocument.Parse(System.IO.File.ReadAllBytes(path));
                Cache[kind] = doc;
            }
            return doc.RootElement;
        }
    }

    public static IEnumerable<object[]> Names(string kind, Func<JsonElement, bool>? where = null) =>
        File(kind).GetProperty("cases").EnumerateArray()
            .Where(c => where?.Invoke(c) ?? true)
            .Select(c => new object[] { c.GetProperty("name").GetString()! });

    public static JsonElement Case(string kind, string name) =>
        File(kind).GetProperty("cases").EnumerateArray().Single(c => c.GetProperty("name").GetString() == name);

    public static string S(this JsonElement e, string name) => e.GetProperty(name).GetString()!;

    public static string? SOpt(this JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    public static byte[] H(this JsonElement e, string name) => Convert.FromHexString(e.S(name));

    public static double D(this JsonElement e, string name) => e.GetProperty(name).GetDouble();

    public static bool B(this JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    public static bool Has(this JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind != JsonValueKind.Null;
}
