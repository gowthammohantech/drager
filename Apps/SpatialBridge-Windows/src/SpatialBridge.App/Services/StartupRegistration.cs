using Microsoft.Win32;
using SpatialBridge.Platform.Windows.Interop;
using Windows.ApplicationModel;

namespace SpatialBridge.App.Services;

/// <summary>Start at login: the MSIX StartupTask when packaged, the HKCU Run key when unpackaged.</summary>
internal static class StartupRegistration
{
    public const string TaskId = "SpatialBridgeStartup";
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "SpatialBridge";

    public static bool IsPackaged { get; } = PackageIdentity.IsPackaged();

    public static async Task<bool> IsEnabledAsync()
    {
        if (IsPackaged)
        {
            var task = await StartupTask.GetAsync(TaskId);
            return task.State is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;
        }
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        return key?.GetValue(RunValueName) is string;
    }

    /// <summary>Returns the resulting state; the user or policy may keep it disabled.</summary>
    public static async Task<bool> SetEnabledAsync(bool enabled)
    {
        if (IsPackaged)
        {
            var task = await StartupTask.GetAsync(TaskId);
            if (enabled)
            {
                var state = await task.RequestEnableAsync();
                return state is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;
            }
            task.Disable();
            return false;
        }

        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
        if (enabled)
        {
            var exe = Environment.ProcessPath ?? throw new InvalidOperationException("No process path");
            key.SetValue(RunValueName, $"\"{exe}\" --background", RegistryValueKind.String);
            return true;
        }
        key.DeleteValue(RunValueName, throwOnMissingValue: false);
        return false;
    }
}
