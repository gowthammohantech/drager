using SpatialBridge.Core;
using SpatialBridge.Core.Services;
using SpatialBridge.Platform.Windows.Discovery;
using SpatialBridge.Platform.Windows.Security;
using SpatialBridge.Platform.Windows.Storage;

namespace SpatialBridge.App.Services;

/// <summary>
/// Production composition: Core's <see cref="ReceiverService"/> with the Windows platform services.
/// <list type="bullet">
/// <item>Secrets (identity seed, PSKs): <see cref="DpapiSecretStore"/> under <c>%LOCALAPPDATA%\SpatialBridge\Secrets</c>.</item>
/// <item>Trusted peers (public metadata only): <see cref="FileTrustedPeerStore"/> at <c>%LOCALAPPDATA%\SpatialBridge\trusted-peers.json</c>.</item>
/// <item>Discovery: <see cref="DnsSdServiceAdvertiser"/>. Commit: <see cref="WindowsFileCommitter"/> (flush, exclusive move, MotW).</item>
/// </list>
/// Staging stays in <c>&lt;destination&gt;\.spatialbridge-staging</c> (hidden; same volume as the final rename).
/// </summary>
internal static class ReceiverFactory
{
    public static ReceiverService CreateProduction(string? destinationFolder) => new(
        new ReceiverOptions
        {
            DisplayName = Environment.MachineName,
            Model = "PC",
            Platform = DevicePlatform.Windows,
            DestinationFolder = destinationFolder,
            // Core's log lines are already redacted (codes and short peer IDs, never names, paths or secrets).
            Log = line => DiagnosticsLog.Shared.Write("core " + line),
        },
        new DpapiSecretStore(),
        new FileTrustedPeerStore(AppPaths.TrustedPeersFile),
        new DnsSdServiceAdvertiser(),
        new WindowsFileCommitter());
}
