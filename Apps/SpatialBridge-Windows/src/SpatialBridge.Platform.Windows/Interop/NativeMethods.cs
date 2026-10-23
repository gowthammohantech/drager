using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

namespace SpatialBridge.Platform.Windows.Interop;

#pragma warning disable SA1300, IDE1006 // Win32 names are kept as documented.

[StructLayout(LayoutKind.Sequential)]
internal struct NativeRect
{
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct MonitorInfoEx
{
    public int cbSize;
    public NativeRect rcMonitor;
    public NativeRect rcWork;
    public uint dwFlags;
    public fixed char szDevice[32];
}

/// <summary>DNS_SERVICE_REGISTER_REQUEST (windns.h).</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct DnsServiceRegisterRequest
{
    public uint Version;
    public uint InterfaceIndex;
    public nint pServiceInstance;
    public delegate* unmanaged[Stdcall]<uint, void*, nint, void> pRegisterCompletionCallback;
    public void* pQueryContext;
    public nint hCredentials;
    public int unicastEnabled;
}

/// <summary>DNS_SERVICE_CANCEL (windns.h).</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct DnsServiceCancel
{
    public nint reserved;
}

internal static unsafe partial class NativeMethods
{
    // dnsapi.dll: DNS-SD registration, Windows 10 1809 (17763) and later.
    internal const uint DnsQueryRequestVersion1 = 1;
    internal const uint DnsRequestPending = 9506;

    [LibraryImport("dnsapi.dll", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial nint DnsServiceConstructInstance(
        string pServiceName,
        string pHostName,
        uint* pIp4,
        void* pIp6,
        ushort wPort,
        ushort wPriority,
        ushort wWeight,
        uint dwPropertiesCount,
        nint* keys,
        nint* values);

    [LibraryImport("dnsapi.dll")]
    internal static partial void DnsServiceFreeInstance(nint pInstance);

    [LibraryImport("dnsapi.dll")]
    internal static partial uint DnsServiceRegister(DnsServiceRegisterRequest* pRequest, DnsServiceCancel* pCancel);

    [LibraryImport("dnsapi.dll")]
    internal static partial uint DnsServiceDeRegister(DnsServiceRegisterRequest* pRequest, DnsServiceCancel* pCancel);

    [LibraryImport("dnsapi.dll")]
    internal static partial uint DnsServiceRegisterCancel(DnsServiceCancel* pCancelHandle);

    // kernel32.dll: durable, exclusive commit.
    internal const uint MoveFileWriteThrough = 0x8;
    internal const int ErrorFileNotFound = 2;
    internal const int ErrorPathNotFound = 3;
    internal const int ErrorAccessDenied = 5;
    internal const int ErrorNotSameDevice = 17;
    internal const int ErrorHandleDiskFull = 39;
    internal const int ErrorFileExists = 80;
    internal const int ErrorDiskFull = 112;
    internal const int ErrorInsufficientBuffer = 122;
    internal const int ErrorAlreadyExists = 183;
    internal const int AppModelErrorNoPackage = 15700;

    [LibraryImport("kernel32.dll", EntryPoint = "MoveFileExW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool MoveFileEx(string lpExistingFileName, string lpNewFileName, uint dwFlags);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool FlushFileBuffers(SafeFileHandle hFile);

    [LibraryImport("kernel32.dll")]
    internal static partial int GetCurrentPackageFullName(ref uint packageFullNameLength, char* packageFullName);

    // user32.dll / shcore.dll: monitors, DPI and animation settings.
    internal const uint MonitorInfoFPrimary = 0x1;
    internal const int MdtEffectiveDpi = 0;
    internal const uint SpiGetClientAreaAnimation = 0x1042;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool EnumDisplayMonitors(
        nint hdc,
        NativeRect* lprcClip,
        delegate* unmanaged[Stdcall]<nint, nint, NativeRect*, nint, int> lpfnEnum,
        nint dwData);

    [LibraryImport("user32.dll", EntryPoint = "GetMonitorInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetMonitorInfo(nint hMonitor, MonitorInfoEx* lpmi);

    [LibraryImport("shcore.dll")]
    internal static partial int GetDpiForMonitor(nint hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    [LibraryImport("user32.dll", EntryPoint = "SystemParametersInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SystemParametersInfo(uint uiAction, uint uiParam, void* pvParam, uint fWinIni);

    // ole32.dll: COM for INetworkListManager.
    internal const uint ClsctxAll = 0x17;
    internal const uint CoinitMultithreaded = 0x0;
    internal const int RpcEChangedMode = unchecked((int)0x80010106);

    [LibraryImport("ole32.dll")]
    internal static partial int CoInitializeEx(nint pvReserved, uint dwCoInit);

    [LibraryImport("ole32.dll")]
    internal static partial void CoUninitialize();

    [LibraryImport("ole32.dll")]
    internal static partial int CoCreateInstance(Guid* rclsid, nint pUnkOuter, uint dwClsContext, Guid* riid, nint* ppv);
}
