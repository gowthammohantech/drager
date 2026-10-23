using SpatialBridge.Platform.Windows.Interop;

namespace SpatialBridge.Platform.Windows.Display;

/// <summary>Windows "Animation effects" (Settings › Accessibility › Visual effects), the Windows analogue of Reduce Motion.</summary>
public static unsafe class AnimationSettings
{
    /// <summary><c>SPI_GETCLIENTAREAANIMATION</c>; true when unknown so the default experience is animated.</summary>
    public static bool ClientAreaAnimationsEnabled()
    {
        if (!OperatingSystem.IsWindows())
        {
            return true;
        }
        int enabled = 1;
        return !NativeMethods.SystemParametersInfo(NativeMethods.SpiGetClientAreaAnimation, 0, &enabled, 0) || enabled != 0;
    }
}
