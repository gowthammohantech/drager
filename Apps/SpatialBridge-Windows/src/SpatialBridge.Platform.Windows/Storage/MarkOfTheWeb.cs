using System.Text;

namespace SpatialBridge.Platform.Windows.Storage;

/// <summary>
/// Mark-of-the-Web (ADR-015): received files get a <c>Zone.Identifier</c> alternate data stream with
/// <c>ZoneId=3</c> (Internet), so SmartScreen and Office treat them as downloaded content.
/// </summary>
public static class MarkOfTheWeb
{
    public const string StreamName = "Zone.Identifier";
    public const int InternetZoneId = 3;

    /// <summary>The exact stream content, ASCII without a BOM.</summary>
    public const string Content = "[ZoneTransfer]\r\nZoneId=3\r\n";

    public static string StreamPath(string filePath)
    {
        ArgumentException.ThrowIfNullOrEmpty(filePath);
        return filePath + ":" + StreamName;
    }

    public static byte[] ContentBytes() => Encoding.ASCII.GetBytes(Content);

    /// <summary>Writes the stream. Returns false where ADS are unsupported (FAT32/exFAT, network shares) instead of failing the transfer.</summary>
    public static bool TryApply(string filePath)
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }
        try
        {
            using var stream = new FileStream(StreamPath(filePath), FileMode.Create, FileAccess.Write, FileShare.None);
            stream.Write(ContentBytes());
            stream.Flush(flushToDisk: true);
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
        catch (NotSupportedException)
        {
            return false;
        }
    }

    /// <summary>True if the file carries a Zone.Identifier with ZoneId=3 or higher.</summary>
    public static bool IsApplied(string filePath)
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }
        try
        {
            return ParseZoneId(File.ReadAllText(StreamPath(filePath), Encoding.ASCII)) >= InternetZoneId;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>Reads <c>ZoneId</c> from a Zone.Identifier body; -1 if absent.</summary>
    public static int ParseZoneId(string content)
    {
        ArgumentNullException.ThrowIfNull(content);
        var inSection = false;
        foreach (var raw in content.Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith('['))
            {
                inSection = string.Equals(line, "[ZoneTransfer]", StringComparison.OrdinalIgnoreCase);
                continue;
            }
            if (inSection && line.StartsWith("ZoneId=", StringComparison.OrdinalIgnoreCase)
                && int.TryParse(line.AsSpan("ZoneId=".Length), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var zone))
            {
                return zone;
            }
        }
        return -1;
    }
}
