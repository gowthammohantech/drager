using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using SpatialBridge.Core;
using SpatialBridge.Platform.Windows.Contracts;
using SpatialBridge.Platform.Windows.Interop;

namespace SpatialBridge.Platform.Windows.Discovery;

/// <summary>Raised when a registration finishes or fails. <see cref="Status"/> is a Win32/DNS status (0 = success).</summary>
public sealed class AdvertiserStatusEventArgs(ServiceRole role, uint status) : EventArgs
{
    public ServiceRole Role { get; } = role;

    public uint Status { get; } = status;

    public bool Succeeded => Status == 0;
}

/// <summary>
/// Advertises <c>_spatialbridge._tcp.local</c> through the Windows DNS-SD API
/// (<c>DnsServiceRegister</c>, Windows 10 1809+). One instance per <see cref="ServiceRole"/>:
/// the receiver keeps <c>role=session</c> up while available and adds <c>role=pairing</c>
/// only while pairing is allowed.
/// </summary>
public sealed class DnsSdServiceAdvertiser : IServiceAdvertiser
{
    private static readonly TimeSpan RegistrationTimeout = TimeSpan.FromSeconds(15);

    private readonly Lock _gate = new();
    private readonly Dictionary<ServiceRole, Registration> _registrations = [];
    private readonly string _hostName;
    private bool _disposed;

    /// <param name="hostName">mDNS host name without <c>.local</c>; defaults to the machine's DNS host name.</param>
    public DnsSdServiceAdvertiser(string? hostName = null)
    {
        _hostName = (hostName ?? System.Net.Dns.GetHostName()).TrimEnd('.') + ".local";
    }

    public event EventHandler<AdvertiserStatusEventArgs>? StatusChanged;

    /// <summary>Roles currently registered (or registering).</summary>
    public IReadOnlyCollection<ServiceRole> ActiveRoles
    {
        get
        {
            lock (_gate)
            {
                return [.. _registrations.Keys];
            }
        }
    }

    public async Task AdvertiseAsync(ServiceRole role, AdvertisedDevice device, int port, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(device);
        ArgumentOutOfRangeException.ThrowIfLessThan(port, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(port, ushort.MaxValue);
        ObjectDisposedException.ThrowIf(_disposed, this);

        await WithdrawAsync(role, cancellationToken).ConfigureAwait(false);

        var instance = TxtRecord.InstanceName(device.DisplayName, role);
        var registration = new Registration(role, TxtRecord.FullServiceName(instance), _hostName, (ushort)port, TxtRecord.Build(device, role), OnStatus);
        lock (_gate)
        {
            _registrations[role] = registration;
        }

        try
        {
            registration.Start();
            var status = await registration.Registered.WaitAsync(RegistrationTimeout, cancellationToken).ConfigureAwait(false);
            if (status != 0)
            {
                throw new BridgeException(BridgeErrorCode.LocalNetworkDenied, $"DnsServiceRegister completed with {status}");
            }
        }
        catch
        {
            lock (_gate)
            {
                if (_registrations.TryGetValue(role, out var current) && ReferenceEquals(current, registration))
                {
                    _registrations.Remove(role);
                }
            }
            await registration.StopAsync().ConfigureAwait(false);
            throw;
        }
    }

    public async Task WithdrawAsync(ServiceRole role, CancellationToken cancellationToken = default)
    {
        Registration? registration;
        lock (_gate)
        {
            _registrations.Remove(role, out registration);
        }
        if (registration is not null)
        {
            await registration.StopAsync().WaitAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Registration[] all;
        lock (_gate)
        {
            all = [.. _registrations.Values];
            _registrations.Clear();
        }
        foreach (var registration in all)
        {
            await registration.StopAsync().ConfigureAwait(false);
        }
    }

    private void OnStatus(ServiceRole role, uint status) => StatusChanged?.Invoke(this, new AdvertiserStatusEventArgs(role, status));

    /// <summary>
    /// One native registration. Owns the constructed instance, the request block and a GCHandle used as
    /// the callback context. Native memory is freed only after deregistration completes; if Windows never
    /// calls back, it is deliberately leaked rather than risking a use-after-free.
    /// </summary>
    private sealed class Registration
    {
        private static readonly TimeSpan DeregistrationTimeout = TimeSpan.FromSeconds(3);

        private readonly ServiceRole _role;
        private readonly string _serviceName;
        private readonly string _hostName;
        private readonly ushort _port;
        private readonly IReadOnlyList<KeyValuePair<string, string>> _txt;
        private readonly Action<ServiceRole, uint> _onStatus;
        private readonly TaskCompletionSource<uint> _registered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<uint> _deregistered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly Lock _gate = new();

        private GCHandle _self;
        private nint _instance;
        private nint _request; // DnsServiceRegisterRequest*
        private nint _cancel;  // DnsServiceCancel*
        private bool _deregistering;
        private bool _stopped;

        public Registration(ServiceRole role, string serviceName, string hostName, ushort port, IReadOnlyList<KeyValuePair<string, string>> txt, Action<ServiceRole, uint> onStatus)
        {
            _role = role;
            _serviceName = serviceName;
            _hostName = hostName;
            _port = port;
            _txt = txt;
            _onStatus = onStatus;
        }

        public Task<uint> Registered => _registered.Task;

        public unsafe void Start()
        {
            var count = _txt.Count;
            var keys = stackalloc nint[count];
            var values = stackalloc nint[count];
            try
            {
                for (var i = 0; i < count; i++)
                {
                    keys[i] = Marshal.StringToHGlobalUni(_txt[i].Key);
                    values[i] = Marshal.StringToHGlobalUni(_txt[i].Value);
                }
                // The API copies the strings into the instance it allocates.
                _instance = NativeMethods.DnsServiceConstructInstance(_serviceName, _hostName, null, null, _port, 0, 0, (uint)count, keys, values);
            }
            finally
            {
                for (var i = 0; i < count; i++)
                {
                    if (keys[i] != 0)
                    {
                        Marshal.FreeHGlobal(keys[i]);
                    }
                    if (values[i] != 0)
                    {
                        Marshal.FreeHGlobal(values[i]);
                    }
                }
            }
            if (_instance == 0)
            {
                throw new BridgeException(BridgeErrorCode.LocalNetworkDenied, "DnsServiceConstructInstance failed");
            }

            _self = GCHandle.Alloc(this);
            var request = (DnsServiceRegisterRequest*)NativeMemory.AllocZeroed((nuint)sizeof(DnsServiceRegisterRequest));
            _request = (nint)request;
            _cancel = (nint)NativeMemory.AllocZeroed((nuint)sizeof(DnsServiceCancel));
            request->Version = NativeMethods.DnsQueryRequestVersion1;
            request->InterfaceIndex = 0; // all interfaces
            request->pServiceInstance = _instance;
            request->pRegisterCompletionCallback = &OnComplete;
            request->pQueryContext = (void*)GCHandle.ToIntPtr(_self);
            request->unicastEnabled = 0;

            var result = NativeMethods.DnsServiceRegister(request, (DnsServiceCancel*)_cancel);
            if (result != NativeMethods.DnsRequestPending)
            {
                _registered.TrySetResult(result == 0 ? uint.MaxValue : result);
            }
        }

        public async Task StopAsync()
        {
            bool callDeregister;
            lock (_gate)
            {
                if (_stopped)
                {
                    return;
                }
                _stopped = true;
                callDeregister = _request != 0 && _registered.Task.IsCompletedSuccessfully && _registered.Task.Result == 0;
                _deregistering = callDeregister;
            }

            if (_request == 0)
            {
                FreeInstance();
                return;
            }

            if (!_registered.Task.IsCompleted)
            {
                // Still probing: cancel the pending registration instead.
                CancelPending();
                var finished = await Task.WhenAny(_registered.Task, Task.Delay(DeregistrationTimeout)).ConfigureAwait(false);
                if (finished != _registered.Task)
                {
                    return; // leak: Windows may still call back into this context.
                }
                if (_registered.Task.Result == 0)
                {
                    lock (_gate)
                    {
                        _deregistering = callDeregister = true;
                    }
                }
            }

            if (callDeregister)
            {
                var result = Deregister();
                if (result == NativeMethods.DnsRequestPending)
                {
                    var finished = await Task.WhenAny(_deregistered.Task, Task.Delay(DeregistrationTimeout)).ConfigureAwait(false);
                    if (finished != _deregistered.Task)
                    {
                        return; // leak, see class remarks.
                    }
                }
            }

            FreeAll();
        }

        private void Complete(uint status)
        {
            bool deregistering;
            lock (_gate)
            {
                deregistering = _deregistering;
            }
            if (deregistering)
            {
                _deregistered.TrySetResult(status);
                return;
            }
            if (_registered.TrySetResult(status))
            {
                _onStatus(_role, status);
            }
        }

        private unsafe void CancelPending() => _ = NativeMethods.DnsServiceRegisterCancel((DnsServiceCancel*)_cancel);

        private unsafe uint Deregister() => NativeMethods.DnsServiceDeRegister((DnsServiceRegisterRequest*)_request, null);

        private void FreeInstance()
        {
            if (_instance != 0)
            {
                NativeMethods.DnsServiceFreeInstance(_instance);
                _instance = 0;
            }
        }

        private unsafe void FreeAll()
        {
            FreeInstance();
            if (_request != 0)
            {
                NativeMemory.Free((void*)_request);
                _request = 0;
            }
            if (_cancel != 0)
            {
                NativeMemory.Free((void*)_cancel);
                _cancel = 0;
            }
            if (_self.IsAllocated)
            {
                _self.Free();
            }
        }

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
        private static unsafe void OnComplete(uint status, void* context, nint instance)
        {
            // Windows hands us a copy of the instance that the callee must free.
            if (instance != 0)
            {
                NativeMethods.DnsServiceFreeInstance(instance);
            }
            if (context is null)
            {
                return;
            }
            try
            {
                if (GCHandle.FromIntPtr((nint)context).Target is Registration registration)
                {
                    registration.Complete(status);
                }
            }
#pragma warning disable CA1031 // An exception must never unwind into dnsapi.
            catch (Exception)
#pragma warning restore CA1031
            {
            }
        }
    }
}
