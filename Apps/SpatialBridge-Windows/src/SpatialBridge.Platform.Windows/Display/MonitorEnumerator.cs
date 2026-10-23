using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using SpatialBridge.Platform.Windows.Interop;

namespace SpatialBridge.Platform.Windows.Display;

/// <summary>
/// Monitors via <c>EnumDisplayMonitors</c>, <c>GetMonitorInfo</c> and <c>GetDpiForMonitor</c>.
/// Requires a per-monitor DPI v2 process (app.manifest) so the rectangles are physical pixels.
/// </summary>
public static unsafe class MonitorEnumerator
{
    public static IReadOnlyList<MonitorGeometry> GetMonitors()
    {
        if (!OperatingSystem.IsWindows())
        {
            return [];
        }
        var handles = new List<nint>();
        var context = GCHandle.Alloc(handles);
        try
        {
            NativeMethods.EnumDisplayMonitors(0, null, &Collect, GCHandle.ToIntPtr(context));
        }
        finally
        {
            context.Free();
        }

        var monitors = new List<MonitorGeometry>(handles.Count);
        foreach (var handle in handles)
        {
            var info = default(MonitorInfoEx);
            info.cbSize = sizeof(MonitorInfoEx);
            if (!NativeMethods.GetMonitorInfo(handle, &info))
            {
                continue;
            }
            var dpi = NativeMethods.GetDpiForMonitor(handle, NativeMethods.MdtEffectiveDpi, out var dpiX, out _) == 0 && dpiX > 0 ? dpiX : 96u;
            var device = new string(info.szDevice);
            monitors.Add(FromNative(device, info.rcMonitor, info.rcWork, dpi, (info.dwFlags & NativeMethods.MonitorInfoFPrimary) != 0, monitors.Count + 1));
        }
        return monitors;
    }

    internal static MonitorGeometry FromNative(string deviceName, NativeRect monitor, NativeRect work, uint dpi, bool primary, int ordinal)
    {
        var name = deviceName.TrimEnd('\0');
        var identifier = string.IsNullOrEmpty(name) ? $"monitor-{ordinal}" : name;
        var label = primary ? $"Display {ordinal} (main)" : $"Display {ordinal}";
        return new MonitorGeometry(
            identifier,
            label,
            RectD.FromEdges(monitor.Left, monitor.Top, monitor.Right, monitor.Bottom),
            RectD.FromEdges(work.Left, work.Top, work.Right, work.Bottom),
            dpi / 96.0,
            primary);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static int Collect(nint monitor, nint hdc, NativeRect* clip, nint data)
    {
        if (GCHandle.FromIntPtr(data).Target is List<nint> list)
        {
            list.Add(monitor);
        }
        return 1; // continue
    }
}
