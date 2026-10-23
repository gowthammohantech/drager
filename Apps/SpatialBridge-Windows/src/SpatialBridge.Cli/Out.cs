using System.Security.Cryptography;
using SpatialBridge.Core;
using SpatialBridge.Core.Json;

namespace SpatialBridge.Cli;

/// <summary>JSON-lines events (CONFORMANCE.md §5). Never pass filenames, contents, PSKs or seeds.</summary>
internal static class Out
{
    private static readonly Lock Gate = new();

    public static void Event(string name, params (string Key, object? Value)[] fields)
    {
        var obj = new JsonObject().Add("event", name);
        foreach (var (key, value) in fields) obj.Add(key, value);
        var line = CanonicalJson.EncodeToString(obj);
        lock (Gate)
        {
            Console.Out.WriteLine(line);
            Console.Out.Flush();
        }
    }

    public static void Error(BridgeErrorCode code) => Event("error", ("code", code.ToWire()));

    public static void Log(string message)
    {
        lock (Gate)
        {
            Console.Error.WriteLine($"sb-dotnet: {message}");
        }
    }

    public static string PskFingerprint(byte[] psk) => Convert.ToHexStringLower(SHA256.HashData(psk))[..16];
}
