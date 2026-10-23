using System.Diagnostics;

namespace SpatialBridge.App.Services;

internal static class Explorer
{
    /// <summary>Opens Explorer with the file selected; falls back to the folder if the file is gone.</summary>
    public static void Reveal(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
            }
            else if (Path.GetDirectoryName(path) is { } folder && Directory.Exists(folder))
            {
                OpenFolder(folder);
            }
        }
        catch (System.ComponentModel.Win32Exception error)
        {
            DiagnosticsLog.Shared.Write("explorer.failed " + error.NativeErrorCode);
        }
    }

    public static void OpenFolder(string folder)
    {
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
        }
        catch (System.ComponentModel.Win32Exception error)
        {
            DiagnosticsLog.Shared.Write("explorer.failed " + error.NativeErrorCode);
        }
    }
}
