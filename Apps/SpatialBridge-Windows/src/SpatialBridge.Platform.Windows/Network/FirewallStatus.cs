using SpatialBridge.Platform.Windows.Interop;

namespace SpatialBridge.Platform.Windows.Network;

/// <summary>NLM_NETWORK_CATEGORY.</summary>
public enum NetworkCategory
{
    Public = 0,
    Private = 1,
    DomainAuthenticated = 2,
}

/// <summary>Result of a read-only firewall-profile check. <see cref="Warning"/> is user-facing copy, or null when all is well.</summary>
public sealed record FirewallAssessment(bool Known, bool OnPublicNetwork, string? Warning)
{
    public static FirewallAssessment Unknown { get; } = new(false, false, null);
}

/// <summary>
/// Detects whether a connected network uses the Public profile, where the MSIX firewall rule (Private only)
/// and Windows' defaults block incoming connections from the phone. It never changes firewall settings.
/// </summary>
public static class FirewallStatus
{
    public const string PublicNetworkWarning =
        "Your network is set to Public, so Windows Firewall blocks phones from reaching this PC. " +
        "If this is your home or work network, open Settings › Network & internet, choose the network and set its profile type to Private.";

    /// <summary>Pure decision used by <see cref="Check"/>.</summary>
    public static FirewallAssessment Evaluate(IReadOnlyCollection<NetworkCategory> connectedNetworks)
    {
        ArgumentNullException.ThrowIfNull(connectedNetworks);
        if (connectedNetworks.Count == 0)
        {
            return new FirewallAssessment(true, false, null);
        }
        var onPublic = connectedNetworks.Contains(NetworkCategory.Public);
        return new FirewallAssessment(true, onPublic, onPublic ? PublicNetworkWarning : null);
    }

    /// <summary>Queries INetworkListManager on a dedicated MTA thread. Returns <see cref="FirewallAssessment.Unknown"/> on any failure.</summary>
    public static FirewallAssessment Check()
    {
        if (!OperatingSystem.IsWindows())
        {
            return FirewallAssessment.Unknown;
        }
        IReadOnlyCollection<NetworkCategory>? categories = null;
        var thread = new Thread(() => categories = NetworkListManager.ConnectedNetworkCategories())
        {
            IsBackground = true,
            Name = "SpatialBridge.FirewallStatus",
        };
        thread.Start();
        if (!thread.Join(TimeSpan.FromSeconds(5)) || categories is null)
        {
            return FirewallAssessment.Unknown;
        }
        return Evaluate(categories);
    }

    public static Task<FirewallAssessment> CheckAsync() => Task.Run(Check);
}

/// <summary>Minimal raw-vtable client for netlistmgr.h's INetworkListManager / IEnumNetworks / INetwork (all IDispatch-derived).</summary>
internal static unsafe class NetworkListManager
{
    private static readonly Guid ClsidNetworkListManager = new("DCB00C01-570F-4A9B-8D69-199FDBA5723B");
    private static readonly Guid IidINetworkListManager = new("DCB00000-570F-4A9B-8D69-199FDBA5723B");

    private const int NlmEnumNetworkConnected = 0x01;

    // Vtable slots: IUnknown 0-2, IDispatch 3-6.
    private const int SlotRelease = 2;
    private const int SlotGetNetworks = 7;        // INetworkListManager::GetNetworks
    private const int SlotEnumNext = 8;           // IEnumNetworks::Next
    private const int SlotGetCategory = 18;       // INetwork::GetCategory

    /// <summary>Categories of connected networks, or null if COM or the service is unavailable.</summary>
    public static IReadOnlyCollection<NetworkCategory>? ConnectedNetworkCategories()
    {
        var init = NativeMethods.CoInitializeEx(0, NativeMethods.CoinitMultithreaded);
        var uninitialize = init >= 0; // S_OK or S_FALSE
        if (init < 0 && init != NativeMethods.RpcEChangedMode)
        {
            return null;
        }
        nint manager = 0;
        nint enumerator = 0;
        try
        {
            var clsid = ClsidNetworkListManager;
            var iid = IidINetworkListManager;
            if (NativeMethods.CoCreateInstance(&clsid, 0, NativeMethods.ClsctxAll, &iid, &manager) < 0 || manager == 0)
            {
                return null;
            }
            var getNetworks = (delegate* unmanaged[Stdcall]<nint, int, nint*, int>)VTable(manager)[SlotGetNetworks];
            if (getNetworks(manager, NlmEnumNetworkConnected, &enumerator) < 0 || enumerator == 0)
            {
                return null;
            }

            var categories = new List<NetworkCategory>();
            var next = (delegate* unmanaged[Stdcall]<nint, uint, nint*, uint*, int>)VTable(enumerator)[SlotEnumNext];
            for (var guard = 0; guard < 64; guard++)
            {
                nint network = 0;
                uint fetched = 0;
                var hr = next(enumerator, 1, &network, &fetched);
                if (hr < 0 || fetched == 0 || network == 0)
                {
                    break;
                }
                try
                {
                    var getCategory = (delegate* unmanaged[Stdcall]<nint, int*, int>)VTable(network)[SlotGetCategory];
                    int category;
                    if (getCategory(network, &category) >= 0 && Enum.IsDefined((NetworkCategory)category))
                    {
                        categories.Add((NetworkCategory)category);
                    }
                }
                finally
                {
                    Release(network);
                }
            }
            return categories;
        }
        finally
        {
            Release(enumerator);
            Release(manager);
            if (uninitialize)
            {
                NativeMethods.CoUninitialize();
            }
        }
    }

    private static nint* VTable(nint comObject) => *(nint**)comObject;

    private static void Release(nint comObject)
    {
        if (comObject != 0)
        {
            ((delegate* unmanaged[Stdcall]<nint, uint>)VTable(comObject)[SlotRelease])(comObject);
        }
    }
}
