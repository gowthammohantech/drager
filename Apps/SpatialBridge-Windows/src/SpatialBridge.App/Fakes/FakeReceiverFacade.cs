using System.Text;
using SpatialBridge.Core;
using SpatialBridge.Platform.Windows.Storage;

namespace SpatialBridge.App.Fakes;

/// <summary>
/// Stand-in for Core's ReceiverService until XP2b. With <c>--fake</c> it scripts a pairing request
/// (through <see cref="PairingApprover"/>), one transfer that really commits a small text file through
/// <see cref="WindowsFileCommitter"/> (flush, exclusive move, Mark-of-the-Web), and one failed transfer,
/// so the whole UI can be smoke-tested on Windows CI without a phone.
/// </summary>
internal sealed class FakeReceiverFacade : IReceiverFacade
{
    private const string FakePeerID = "a1b2c3d4e5f60718293a4b5c6d7e8f90";

    private readonly List<TrustedPeerInfo> _trusted = [];
    private readonly Lock _gate = new();
    private readonly CancellationTokenSource _stop = new();
    private Task? _script;

    public FakeReceiverFacade(bool scripted)
    {
        Scripted = scripted;
        _trusted.Add(new TrustedPeerInfo("0f1e2d3c4b5a69788796a5b4c3d2e1f0", "Gowtham's iPhone", DevicePlatform.IOS, DateTimeOffset.Now.AddDays(-3)));
    }

    public event EventHandler<ReceiverEvent>? EventRaised;

    public Func<PairingPrompt, CancellationToken, Task<bool>>? PairingApprover { get; set; }

    public bool Scripted { get; }

    /// <summary>Set when the scripted transfer reached COMMITTED (used by <c>--smoke-test</c>).</summary>
    public bool ScriptCommitted { get; private set; }

    public bool IsAvailable { get; private set; }

    public bool AllowPairing { get; private set; }

    public string? DestinationFolder { get; private set; }

    public IReadOnlyList<TrustedPeerInfo> TrustedPeers
    {
        get
        {
            lock (_gate)
            {
                return [.. _trusted];
            }
        }
    }

    public Task SetAvailableAsync(bool available, CancellationToken cancellationToken = default)
    {
        IsAvailable = available;
        Raise(new ReceiverEvent.AvailabilityChanged(available));
        return Task.CompletedTask;
    }

    public Task SetAllowPairingAsync(bool allow, CancellationToken cancellationToken = default)
    {
        AllowPairing = allow;
        return Task.CompletedTask;
    }

    public Task SetDestinationFolderAsync(string folder, CancellationToken cancellationToken = default)
    {
        DestinationFolder = folder;
        return Task.CompletedTask;
    }

    public Task UnpairAsync(string peerID, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            _trusted.RemoveAll(p => p.PeerID == peerID);
        }
        return Task.CompletedTask;
    }

    /// <summary>Runs the script once (no-op unless <see cref="Scripted"/>). Completes when the script ends.</summary>
    public Task StartScriptAsync()
    {
        if (!Scripted)
        {
            return Task.CompletedTask;
        }
        return _script ??= Task.Run(() => RunScriptAsync(_stop.Token));
    }

    public async ValueTask DisposeAsync()
    {
        await _stop.CancelAsync().ConfigureAwait(false);
        if (_script is not null)
        {
            try
            {
                await _script.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }
        }
        _stop.Dispose();
    }

    private async Task RunScriptAsync(CancellationToken cancellationToken)
    {
        await Task.Delay(1500, cancellationToken).ConfigureAwait(false);
        await SetAvailableAsync(true, cancellationToken).ConfigureAwait(false);

        // 1. Pairing request from an Android phone.
        await Task.Delay(1000, cancellationToken).ConfigureAwait(false);
        var prompt = new PairingPrompt("Pixel 9", DevicePlatform.Android, "482913");
        var approver = PairingApprover;
        var approved = approver is not null && AllowPairing && await approver(prompt, cancellationToken).ConfigureAwait(false);
        if (approved)
        {
            var peer = new TrustedPeerInfo(FakePeerID, prompt.PeerDisplayName, prompt.Platform, DateTimeOffset.Now);
            lock (_gate)
            {
                _trusted.RemoveAll(p => p.PeerID == FakePeerID);
                _trusted.Add(peer);
            }
            Raise(new ReceiverEvent.Paired(peer));
        }
        else
        {
            Raise(new ReceiverEvent.PairingFailed(BridgeErrorCode.PairingRejected));
        }

        // 2. A transfer that commits a real file.
        await Task.Delay(1200, cancellationToken).ConfigureAwait(false);
        Raise(new ReceiverEvent.PeerConnected(FakePeerID, prompt.PeerDisplayName));
        var content = Encoding.UTF8.GetBytes("Spatial Bridge test transfer\r\n" + new string('.', 3000));
        var id = Guid.NewGuid();
        Raise(new ReceiverEvent.TransferIncoming(id, prompt.PeerDisplayName, content.Length, new ExitGesture(Edge.Top, 0.4, 1100, 140, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())));
        for (var step = 1; step <= 8; step++)
        {
            await Task.Delay(150, cancellationToken).ConfigureAwait(false);
            Raise(new ReceiverEvent.TransferProgress(id, content.Length * step / 8, content.Length));
        }

        var folder = DestinationFolder ?? Services.AppPaths.DefaultDestination;
        var staging = Path.Combine(Path.GetTempPath(), "SpatialBridge", "staging");
        Directory.CreateDirectory(staging);
        var staged = Path.Combine(staging, id.ToString("N") + ".part");
        await File.WriteAllBytesAsync(staged, content, cancellationToken).ConfigureAwait(false);
        try
        {
            Directory.CreateDirectory(folder);
            var saved = await new WindowsFileCommitter().CommitAsync(staged, folder, "Spatial Bridge Test.txt", cancellationToken).ConfigureAwait(false);
            ScriptCommitted = true;
            Raise(new ReceiverEvent.TransferCommitted(id, saved, content.Length));
        }
        catch (BridgeException error)
        {
            File.Delete(staged);
            Raise(new ReceiverEvent.TransferFailed(id, error.Code));
        }

        // 3. A transfer that fails verification (never shows success).
        await Task.Delay(3500, cancellationToken).ConfigureAwait(false);
        var failing = Guid.NewGuid();
        Raise(new ReceiverEvent.TransferIncoming(failing, prompt.PeerDisplayName, 1_048_576, new ExitGesture(Edge.Right, 0.6, 500, 90, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())));
        await Task.Delay(400, cancellationToken).ConfigureAwait(false);
        Raise(new ReceiverEvent.TransferProgress(failing, 524_288, 1_048_576));
        await Task.Delay(400, cancellationToken).ConfigureAwait(false);
        Raise(new ReceiverEvent.TransferFailed(failing, BridgeErrorCode.HashMismatch));
        Raise(new ReceiverEvent.PeerDisconnected(FakePeerID));
    }

    private void Raise(ReceiverEvent e) => EventRaised?.Invoke(this, e);
}
