namespace SpatialBridge.Platform.Windows.Interop;

/// <summary>Whether the process runs with MSIX package identity (StartupTask, packaged notifications) or unpackaged.</summary>
public static unsafe class PackageIdentity
{
    public static bool IsPackaged()
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }
        uint length = 0;
        var result = NativeMethods.GetCurrentPackageFullName(ref length, null);
        return result == NativeMethods.ErrorInsufficientBuffer;
    }
}
