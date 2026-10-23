using System.Globalization;

namespace SpatialBridge.App.Services;

/// <summary>
/// In-memory ring of redacted events for Export Diagnostics. Callers pass only redacted values
/// (<see cref="Redaction"/>): never filenames, file contents, codes or keys.
/// </summary>
internal sealed class DiagnosticsLog
{
    private const int Capacity = 1000;
    private readonly Queue<string> _lines = new();
    private readonly Lock _gate = new();

    public static DiagnosticsLog Shared { get; } = new();

    public void Write(string redactedLine)
    {
        var line = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture) + " " + redactedLine;
        lock (_gate)
        {
            _lines.Enqueue(line);
            while (_lines.Count > Capacity)
            {
                _lines.Dequeue();
            }
        }
        System.Diagnostics.Debug.WriteLine(line);
    }

    public string[] Snapshot()
    {
        lock (_gate)
        {
            return [.. _lines];
        }
    }
}
