using SpatialBridge.Core.Messages;

namespace SpatialBridge.Core.Transfer;

/// <summary>
/// Accept/reject policy for incoming offers (FR-203, ADR-015). Checks run in the Mac's order, and the
/// Windows policy is never weaker than the Mac's: the Apple denied set by UTI conformance, plus an
/// extension denylist for Windows executables and scripts checked on both the offered and the saved name.
/// </summary>
public sealed record TransferPolicy
{
    public static readonly IReadOnlyList<string> AppleDeniedTypes =
    [
        "com.apple.application", "public.unix-executable", "public.shell-script",
        "com.apple.applescript.text", "com.apple.applescript.script",
    ];

    public static readonly IReadOnlyList<string> WindowsDeniedTypes =
    [
        .. AppleDeniedTypes, "public.executable", "public.script",
        "com.microsoft.windows-executable", "com.microsoft.windows-dynamic-link-library",
        "com.apple.installer-package-archive", "com.apple.disk-image-udif",
    ];

    /// <summary>Executables, scripts, shortcuts, installers and mountable images on Windows, plus the Apple denied set.</summary>
    public static readonly IReadOnlySet<string> DeniedExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "exe", "msi", "msp", "mst", "bat", "cmd", "com", "scr", "pif", "cpl", "msc", "dll", "sys", "drv", "ocx",
        "ps1", "ps1xml", "ps2", "ps2xml", "psc1", "psc2", "psd1", "psm1", "pssc", "cdxml",
        "vb", "vbs", "vbe", "vbscript", "js", "jse", "jscript", "wsf", "wsh", "wsc", "ws", "sct", "hta", "msh", "msh1", "msh2", "mshxml",
        "lnk", "url", "scf", "inf", "reg", "jar", "jnlp", "application", "appref-ms", "gadget", "xbap",
        "appx", "appxbundle", "msix", "msixbundle", "appinstaller", "library-ms", "settingcontent-ms", "searchconnector-ms",
        "chm", "hlp", "mde", "mdb", "ade", "adp", "ins", "isp", "its", "diagcab", "xll", "website",
        "iso", "img", "vhd", "vhdx",
        "sh", "bash", "zsh", "ksh", "csh", "tcsh", "command", "tool", "app", "pkg", "mpkg", "dmg",
        "py", "pyw", "pyc", "pyz", "rb", "pl", "pm", "php", "scpt", "scptd", "applescript", "workflow", "action", "terminal",
    };

    public TransferLimits Limits { get; init; } = TransferLimits.Default;

    public IReadOnlyList<string> DeniedTypes { get; init; } = WindowsDeniedTypes;

    /// <summary>If non-empty, only these types (or subtypes) are accepted.</summary>
    public IReadOnlyList<string> AllowedTypes { get; init; } = [];

    /// <summary>
    /// ADR-015 lets Windows treat unknown UTIs as plain data; the Mac rejects them. Off by default so Windows
    /// is never more permissive than the Mac. <c>dyn.*</c> types are always accepted as data.
    /// </summary>
    public bool AcceptUnknownTypes { get; init; }

    public static TransferPolicy Default { get; } = new();

    /// <summary>Throws <see cref="BridgeException"/> with the rejection reason.</summary>
    public void Validate(TransferOffer offer)
    {
        if (offer.ProtocolVersion != BridgeProtocol.Version) throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "offer version");
        if (offer.ByteCount <= 0) throw new BridgeException(BridgeErrorCode.UnsupportedFile, "empty file");
        if (offer.ByteCount > Limits.MaxFileBytes) throw new BridgeException(BridgeErrorCode.SizeLimit, "too large");
        if (!IsHexDigest(offer.Sha256Hex)) throw new BridgeException(BridgeErrorCode.ProtocolMismatch, "bad digest");
        ValidateName(offer.Filename, offer.ContentType);
    }

    /// <summary>The filename and type checks alone (the <c>uti-policy</c> vectors).</summary>
    public void ValidateName(string filename, string contentType)
    {
        if (!FilenameSanitizer.IsSafe(filename)) throw new BridgeException(BridgeErrorCode.UnsupportedFile, "unsafe filename");
        var type = contentType;
        if (UtiCatalog.IsDynamic(contentType) || (AcceptUnknownTypes && contentType.Length > 0 && !UtiCatalog.IsKnown(contentType)))
        {
            type = "public.data";
        }
        else if (!UtiCatalog.IsKnown(contentType))
        {
            throw new BridgeException(BridgeErrorCode.UnsupportedFile, "unknown type");
        }
        if (DeniedTypes.Any(d => UtiCatalog.ConformsTo(type, d))) throw new BridgeException(BridgeErrorCode.UnsupportedFile, "denied type");
        foreach (var name in new[] { filename, WindowsSaveName.Map(filename) })
        {
            var ext = FilenameSanitizer.SplitExtension(name).Extension;
            if (ext.Length == 0) continue;
            if (DeniedExtensions.Contains(ext)) throw new BridgeException(BridgeErrorCode.UnsupportedFile, "denied extension");
            if (UtiCatalog.TypeForExtension(ext) is { } byExtension && DeniedTypes.Any(d => UtiCatalog.ConformsTo(byExtension, d)))
            {
                throw new BridgeException(BridgeErrorCode.UnsupportedFile, "denied extension");
            }
        }
        if (AllowedTypes.Count > 0 && !AllowedTypes.Any(a => UtiCatalog.ConformsTo(type, a)))
        {
            throw new BridgeException(BridgeErrorCode.UnsupportedFile, "type not allowed");
        }
    }

    /// <summary>64 hex digits; like Swift's <c>Character.isHexDigit</c> this includes fullwidth forms.</summary>
    public static bool IsHexDigest(string s) =>
        Text.GraphemeCount(s) == 64 && s.Length == 64 && s.All(c => char.IsAsciiHexDigit(c) || c is (>= '０' and <= '９') or (>= 'Ａ' and <= 'Ｆ') or (>= 'ａ' and <= 'ｆ'));
}
