namespace SpatialBridge.Core;

public static class Hex
{
    public static string Encode(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(bytes);

    public static byte[]? TryDecode(string? hex)
    {
        if (hex is null || hex.Length % 2 != 0) return null;
        try
        {
            return Convert.FromHexString(hex);
        }
        catch (FormatException)
        {
            return null;
        }
    }

    public static byte[] Decode(string hex) => TryDecode(hex) ?? throw new FormatException("invalid hex");
}
