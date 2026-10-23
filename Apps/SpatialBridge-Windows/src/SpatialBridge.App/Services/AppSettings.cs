using System.Text.Json;
using System.Text.Json.Serialization;

namespace SpatialBridge.App.Services;

/// <summary>App preferences. Protocol state (identity, trusted peers) belongs to Core, not here.</summary>
internal sealed class AppSettings
{
    public bool OverlayEnabled { get; set; } = true;

    /// <summary>Monitor device name (\\.\DISPLAYn); null means the main display.</summary>
    public string? OverlayDisplayId { get; set; }

    public bool KeepHistory { get; set; } = true;

    /// <summary>Last chosen folder, handed to the facade at launch.</summary>
    public string? DestinationFolder { get; set; }
}

internal sealed record HistoryEntry(
    Guid TransferID,
    DateTimeOffset Timestamp,
    string PeerDisplayName,
    long ByteCount,
    string? SavedPath,
    string? ErrorCode);

[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(AppSettings))]
[JsonSerializable(typeof(List<HistoryEntry>))]
internal sealed partial class AppJsonContext : JsonSerializerContext;

internal sealed class SettingsStore
{
    public AppSettings Current { get; private set; } = new();

    public void Load()
    {
        try
        {
            if (File.Exists(AppPaths.SettingsFile))
            {
                Current = JsonSerializer.Deserialize(File.ReadAllBytes(AppPaths.SettingsFile), AppJsonContext.Default.AppSettings) ?? new AppSettings();
            }
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException)
        {
            Current = new AppSettings();
        }
    }

    public void Save()
    {
        try
        {
            AppPaths.WriteAtomically(AppPaths.SettingsFile, JsonSerializer.SerializeToUtf8Bytes(Current, AppJsonContext.Default.AppSettings));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            DiagnosticsLog.Shared.Write("settings.save-failed " + error.GetType().Name);
        }
    }
}

/// <summary>Transfer history: metadata only (no contents), capped, stored locally for Settings › History.</summary>
internal sealed class HistoryStore
{
    private const int MaxEntries = 200;
    private readonly List<HistoryEntry> _entries = [];

    public event EventHandler? Changed;

    public IReadOnlyList<HistoryEntry> Entries => _entries;

    public void Load()
    {
        try
        {
            if (File.Exists(AppPaths.HistoryFile))
            {
                _entries.Clear();
                _entries.AddRange(JsonSerializer.Deserialize(File.ReadAllBytes(AppPaths.HistoryFile), AppJsonContext.Default.ListHistoryEntry) ?? []);
            }
        }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException)
        {
            _entries.Clear();
        }
    }

    public void Add(HistoryEntry entry, bool persist)
    {
        _entries.Insert(0, entry);
        if (_entries.Count > MaxEntries)
        {
            _entries.RemoveRange(MaxEntries, _entries.Count - MaxEntries);
        }
        if (persist)
        {
            Save();
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Clear()
    {
        _entries.Clear();
        Save();
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void Save()
    {
        try
        {
            AppPaths.WriteAtomically(AppPaths.HistoryFile, JsonSerializer.SerializeToUtf8Bytes(_entries, AppJsonContext.Default.ListHistoryEntry));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            DiagnosticsLog.Shared.Write("history.save-failed " + error.GetType().Name);
        }
    }
}
