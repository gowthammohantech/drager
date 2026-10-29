using System.Globalization;
using SpatialBridge.Core;

namespace SpatialBridge.App.Services;

/// <summary>User-facing copy shared by the tray, windows, overlay and notifications. Neutral about the peer's platform (ADR-015).</summary>
internal static class UserText
{
    public static string Message(BridgeErrorCode code) => code switch
    {
        BridgeErrorCode.LocalNetworkDenied => "Drager can't use the local network.",
        BridgeErrorCode.NoPeer => "No device was found nearby.",
        BridgeErrorCode.PairingRejected => "Pairing was declined.",
        BridgeErrorCode.AuthenticationFailed => "The device couldn't be verified.",
        BridgeErrorCode.PeerLost => "The connection to the other device was lost.",
        BridgeErrorCode.UnsupportedFile => "This file type isn't supported.",
        BridgeErrorCode.SizeLimit => "This file is too large to send.",
        BridgeErrorCode.InsufficientStorage => "There isn't enough free space on this PC.",
        BridgeErrorCode.DestinationPermissionExpired => "The save folder isn't available.",
        BridgeErrorCode.HashMismatch => "The file arrived damaged and was discarded.",
        BridgeErrorCode.WriteFailed => "This PC couldn't save the file.",
        BridgeErrorCode.ProtocolMismatch => "The other device is running an incompatible version.",
        BridgeErrorCode.TransferCanceled => "The transfer was cancelled.",
        BridgeErrorCode.Timeout => "The other device didn't respond in time.",
        _ => "Something went wrong.",
    };

    /// <summary>"iPhone", "Android phone", "Mac", "Windows PC"; "device" when unknown.</summary>
    public static string PlatformName(DevicePlatform platform) => platform.Raw switch
    {
        "iOS" => "iPhone",
        "android" => "Android phone",
        "macOS" => "Mac",
        "windows" => "Windows PC",
        _ => "device",
    };

    /// <summary>Segoe Fluent Icons / MDL2 glyph: CellPhone for phones, PC for computers, Devices otherwise.</summary>
    public static string PlatformGlyph(DevicePlatform platform) => platform.Raw switch
    {
        "iOS" or "android" => "",
        "macOS" or "windows" => "",
        _ => "",
    };

    /// <summary>"123 456", easier to compare at a glance.</summary>
    public static string FormatCode(string code) =>
        code.Length == 6 ? string.Concat(code.AsSpan(0, 3), " ", code.AsSpan(3)) : code;

    public static string Bytes(long count)
    {
        string[] units = ["bytes", "KB", "MB", "GB"];
        double value = count;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1)
        {
            value /= 1000;
            unit++;
        }
        return unit == 0
            ? string.Format(CultureInfo.CurrentCulture, "{0:N0} {1}", count, units[0])
            : string.Format(CultureInfo.CurrentCulture, "{0:0.#} {1}", value, units[unit]);
    }
}
