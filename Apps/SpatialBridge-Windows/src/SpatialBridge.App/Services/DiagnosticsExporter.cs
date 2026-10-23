using System.IO.Compression;
using System.Text;
using System.Text.Json;
using SpatialBridge.Platform.Windows.Display;
using SpatialBridge.Platform.Windows.Network;

namespace SpatialBridge.App.Services;

/// <summary>
/// Export Diagnostics…: a zip with environment facts, redacted settings, counts and the redacted event log.
/// It never contains filenames, file contents, peer names, pairing codes or keys.
/// </summary>
internal static class DiagnosticsExporter
{
    public static async Task ExportAsync(string zipPath, AppSettings settings, int trustedPeerCount, IReadOnlyList<HistoryEntry> history, bool available, bool allowPairing)
    {
        var firewall = await FirewallStatus.CheckAsync().ConfigureAwait(false);
        var monitors = MonitorEnumerator.GetMonitors();

        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
        {
            json.WriteStartObject();
            json.WriteString("generatedAt", DateTimeOffset.UtcNow);
            json.WriteString("appVersion", typeof(DiagnosticsExporter).Assembly.GetName().Version?.ToString() ?? "unknown");
            json.WriteString("os", Environment.OSVersion.VersionString);
            json.WriteString("architecture", System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString());
            json.WriteString("runtime", Environment.Version.ToString());
            json.WriteBoolean("packaged", StartupRegistration.IsPackaged);
            json.WriteBoolean("available", available);
            json.WriteBoolean("allowPairing", allowPairing);
            json.WriteBoolean("overlayEnabled", settings.OverlayEnabled);
            json.WriteBoolean("overlayDisplayChosen", settings.OverlayDisplayId is not null);
            json.WriteBoolean("keepHistory", settings.KeepHistory);
            json.WriteBoolean("destinationSet", settings.DestinationFolder is not null);
            json.WriteBoolean("animationEffects", AnimationSettings.ClientAreaAnimationsEnabled());
            json.WriteBoolean("firewallKnown", firewall.Known);
            json.WriteBoolean("publicNetwork", firewall.OnPublicNetwork);
            json.WriteNumber("trustedPeers", trustedPeerCount);
            json.WriteNumber("historyEntries", history.Count);
            json.WriteNumber("historyFailures", history.Count(h => h.ErrorCode is not null));
            json.WriteStartArray("monitors");
            foreach (var monitor in monitors)
            {
                json.WriteStartObject();
                json.WriteNumber("width", monitor.Frame.Width);
                json.WriteNumber("height", monitor.Frame.Height);
                json.WriteNumber("scale", monitor.Scale);
                json.WriteBoolean("primary", monitor.IsPrimary);
                json.WriteEndObject();
            }
            json.WriteEndArray();
            json.WriteStartArray("recentErrors");
            foreach (var entry in history.Where(h => h.ErrorCode is not null).Take(50))
            {
                json.WriteStringValue($"{entry.Timestamp:O} {Redaction.Transfer(entry.TransferID)} {entry.ErrorCode}");
            }
            json.WriteEndArray();
            json.WriteEndObject();
        }

        var temporary = zipPath + ".tmp";
        await using (var file = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
        using (var zip = new ZipArchive(file, ZipArchiveMode.Create))
        {
            var summary = zip.CreateEntry("diagnostics.json", CompressionLevel.Optimal);
            await using (var stream = summary.Open())
            {
                await stream.WriteAsync(buffer.ToArray()).ConfigureAwait(false);
            }
            var log = zip.CreateEntry("events.log", CompressionLevel.Optimal);
            await using (var stream = log.Open())
            {
                var text = string.Join("\r\n", DiagnosticsLog.Shared.Snapshot()) + "\r\n";
                await stream.WriteAsync(Encoding.UTF8.GetBytes(text)).ConfigureAwait(false);
            }
        }
        File.Move(temporary, zipPath, overwrite: true);
    }
}
