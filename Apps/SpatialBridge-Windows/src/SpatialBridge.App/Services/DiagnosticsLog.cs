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

    /// <summary>Optional file sink for CI smoke tests (env <c>SB_DIAG_LOG_FILE</c>); lines are already redacted.</summary>
    private static readonly string? FileSink = Environment.GetEnvironmentVariable("SB_DIAG_LOG_FILE");

    /// <summary>Records an unhandled exception without its message, which may carry user paths.</summary>
    public void WriteException(string where, Exception exception) =>
        Write($"{where} {exception.GetType().FullName} hr=0x{exception.HResult:X8}{Environment.NewLine}{exception.StackTrace}");

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
        if (FileSink is not null)
        {
            try
            {
                lock (_gate)
                {
                    File.AppendAllText(FileSink, line + Environment.NewLine);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    public string[] Snapshot()
    {
        lock (_gate)
        {
            return [.. _lines];
        }
    }
}
