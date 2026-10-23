using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using SpatialBridge.Core.Framing;
using SpatialBridge.Core.Messages;
using SpatialBridge.Core.Net;
using SpatialBridge.Core.Pairing;
using SpatialBridge.Core.Services;
using SpatialBridge.Core.Session;
using SpatialBridge.Core.Tls;
using SpatialBridge.Core.Transfer;

namespace SpatialBridge.Core.Tests;

public sealed class TlsLoopbackTests
{
    private static readonly byte[] Psk = Enumerable.Repeat((byte)0x11, 32).ToArray();
    private const string Identity = "0123456789abcdef0123456789abcdef";

    private static async Task<(Task<PskTlsConnection> Server, Task<PskTlsConnection> Client, IDisposable Cleanup)> Handshake(string identity, byte[] psk)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var accept = listener.AcceptTcpClientAsync();
        var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, port);
        var serverSocket = await accept;
        var server = PskTls.AcceptAsync(serverSocket.GetStream(), id => id == Identity ? Psk : null, TimeSpan.FromSeconds(10));
        var clientTls = PskTls.ConnectAsync(client.GetStream(), identity, psk, TimeSpan.FromSeconds(10));
        return (server, clientTls, new Cleanup(() => { client.Dispose(); serverSocket.Dispose(); listener.Stop(); }));
    }

    private sealed class Cleanup(Action action) : IDisposable
    {
        public void Dispose() => action();
    }

    [Fact]
    public async Task MatchingKeyEchoesBothWays()
    {
        var (server, client, cleanup) = await Handshake(Identity, Psk);
        using var _ = cleanup;
        using var s = await server;
        using var c = await client;
        Assert.Equal(Identity, s.Identity);
        await c.Stream.WriteAsync("ping\n"u8.ToArray());
        var buffer = new byte[5];
        await s.Stream.ReadExactlyAsync(buffer);
        Assert.Equal("ping\n", Encoding.UTF8.GetString(buffer));
        await s.Stream.WriteAsync(buffer);
        var back = new byte[5];
        await c.Stream.ReadExactlyAsync(back);
        Assert.Equal(buffer, back);
    }

    [Fact]
    public async Task WrongKeyFails()
    {
        var (server, client, cleanup) = await Handshake(Identity, Enumerable.Repeat((byte)0x22, 32).ToArray());
        using var _ = cleanup;
        Assert.Equal(BridgeErrorCode.AuthenticationFailed, (await Assert.ThrowsAsync<BridgeException>(() => server)).Code);
        Assert.Equal(BridgeErrorCode.AuthenticationFailed, (await Assert.ThrowsAsync<BridgeException>(() => client)).Code);
    }

    [Fact]
    public async Task UnknownIdentityFails()
    {
        var (server, client, cleanup) = await Handshake("ffffffffffffffffffffffffffffffff", Psk);
        using var _ = cleanup;
        Assert.Equal(BridgeErrorCode.AuthenticationFailed, (await Assert.ThrowsAsync<BridgeException>(() => server)).Code);
        Assert.Equal(BridgeErrorCode.AuthenticationFailed, (await Assert.ThrowsAsync<BridgeException>(() => client)).Code);
    }

    [Fact]
    public async Task FullDuplexUnderLoad()
    {
        var (server, client, cleanup) = await Handshake(Identity, Psk);
        using var _ = cleanup;
        using var s = await server;
        using var c = await client;
        var data = RandomNumberGenerator.GetBytes(4 << 20);
        var write = Task.Run(async () => { for (var i = 0; i < data.Length; i += 65536) await c.Stream.WriteAsync(data.AsMemory(i, 65536)); });
        var echoed = Task.Run(async () => { for (var i = 0; i < 200; i++) await s.Stream.WriteAsync(new byte[1000]); });
        var received = new byte[data.Length];
        await s.Stream.ReadExactlyAsync(received);
        var small = new byte[200_000];
        await c.Stream.ReadExactlyAsync(small);
        await Task.WhenAll(write, echoed);
        Assert.Equal(data, received);
    }
}

/// <summary>Receiver and sender wired over loopback TCP with in-memory stores.</summary>
internal sealed class Rig : IAsyncDisposable
{
    public readonly string Root = Path.Combine(Path.GetTempPath(), "sb-tests-" + Guid.NewGuid().ToString("N"));
    public readonly ReceiverService Receiver;
    public readonly SenderClient Sender;
    public readonly List<ReceiverEvent> Events = [];
    public readonly List<TransferEvent> Transfers = [];
    public bool Approve = true;
    private readonly InMemorySecretStore _senderSecrets = new();
    private readonly InMemoryTrustedPeerStore _senderTrust = new();

    public Rig(TransferLimits? limits = null, ProtocolTimeouts? timeouts = null)
    {
        Directory.CreateDirectory(Dest);
        limits ??= TransferLimits.Default with { TransferIdleTimeout = TimeSpan.FromSeconds(3) };
        timeouts ??= new ProtocolTimeouts { Handshake = TimeSpan.FromSeconds(10), UserDecision = TimeSpan.FromSeconds(10) };
        Receiver = new ReceiverService(new ReceiverOptions
        {
            DisplayName = "Test PC",
            ListenAddress = IPAddress.Loopback,
            DestinationFolder = Dest,
            Policy = TransferPolicy.Default with { Limits = limits },
            Timeouts = timeouts,
        }, new InMemorySecretStore(), new InMemoryTrustedPeerStore());
        Receiver.PairingApprover = (_, _) => Task.FromResult(Approve);
        Receiver.EventRaised += (_, e) => { lock (Events) Events.Add(e); };
        Receiver.TransferEventRaised += (_, e) => { lock (Transfers) Transfers.Add(e); };
        Sender = new SenderClient(_senderSecrets, _senderTrust, "Pixel", DevicePlatform.Android, "Pixel 9") { Timeouts = timeouts, Limits = limits };
    }

    public string Dest => Path.Combine(Root, "out");

    public async Task StartAsync()
    {
        await Receiver.SetAllowPairingAsync(true);
        await Receiver.SetAvailableAsync(true);
    }

    public Task<PairingOutcome> PairAsync(bool approve = true) =>
        Sender.PairAsync("127.0.0.1", Receiver.PairingPort!.Value, (_, _) => Task.FromResult(approve));

    public TrustedPeer Peer => _senderTrust.All().Single();

    public string WriteFile(string name, int bytes, out string sha)
    {
        var path = Path.Combine(Root, name);
        var data = RandomNumberGenerator.GetBytes(bytes);
        File.WriteAllBytes(path, data);
        sha = Convert.ToHexStringLower(SHA256.HashData(data));
        return path;
    }

    public Task<TransferCommitted> SendAsync(string path, string contentType = "public.data", Guid? id = null, SendFault fault = SendFault.None, string? filename = null) =>
        Sender.SendFileAsync("127.0.0.1", Receiver.SessionPort!.Value, Peer, new OutgoingFile(path, filename ?? Path.GetFileName(path), contentType), id, fault);

    public string[] SavedFiles() => [.. Directory.GetFiles(Dest).Select(Path.GetFileName).Order(StringComparer.Ordinal)!];

    public string[] Partials() => [.. Directory.EnumerateFiles(Dest, "*.sbpart", SearchOption.AllDirectories)];

    public async ValueTask DisposeAsync()
    {
        await Receiver.DisposeAsync();
        try { Directory.Delete(Root, true); } catch (IOException) { }
    }
}

public sealed class ReceiverLoopbackTests
{
    [Fact]
    public async Task PairTlsAuthTransferCommit()
    {
        await using var rig = new Rig();
        await rig.StartAsync();
        var outcome = await rig.PairAsync();
        Assert.Equal(rig.Receiver.PeerID, outcome.TrustedPeer.PeerID);
        // The initiator can finish a moment before the responder has verified its confirm and stored trust.
        for (var i = 0; i < 50 && rig.Receiver.TrustedPeers.Count == 0; i++) await Task.Delay(20);
        Assert.Single(rig.Receiver.TrustedPeers);

        var path = rig.WriteFile("photo.jpeg", 1 << 20, out var sha);
        var committed = await rig.SendAsync(path, "public.jpeg");
        Assert.Equal("photo.jpeg", committed.SavedFilename);
        Assert.Equal(1 << 20, committed.ByteCount);
        var saved = Path.Combine(rig.Dest, "photo.jpeg");
        Assert.Equal(sha, Convert.ToHexStringLower(SHA256.HashData(await File.ReadAllBytesAsync(saved))));
        Assert.Empty(rig.Partials());

        // The committed event precedes COMMITTED, so it is already recorded.
        lock (rig.Events)
        {
            Assert.Contains(rig.Events, e => e is ReceiverEvent.Paired);
            Assert.Contains(rig.Events, e => e is ReceiverEvent.TransferIncoming { Filename: "photo.jpeg", ContentType: "public.jpeg" });
            Assert.Contains(rig.Events, e => e is ReceiverEvent.TransferProgress { ReceivedBytes: 1 << 20 });
            Assert.Contains(rig.Events, e => e is ReceiverEvent.TransferCommitted c && c.SavedPath == saved);
        }
    }

    [Fact]
    public async Task ReplayReturnsCommittedWithoutSecondFile()
    {
        await using var rig = new Rig();
        await rig.StartAsync();
        await rig.PairAsync();
        var path = rig.WriteFile("a.txt", 3000, out _);
        var id = Guid.NewGuid();
        var first = await rig.SendAsync(path, "public.plain-text", id);
        var second = await rig.SendAsync(path, "public.plain-text", id);
        Assert.Equal(first, second);
        Assert.Equal(["a.txt"], rig.SavedFiles());
    }

    [Fact]
    public async Task CollisionsAndReservedNames()
    {
        await using var rig = new Rig();
        await rig.StartAsync();
        await rig.PairAsync();
        var path = rig.WriteFile("x.bin", 10, out _);
        Assert.Equal("IMG.jpeg", (await rig.SendAsync(path, "public.jpeg", filename: "IMG.jpeg")).SavedFilename);
        Assert.Equal("IMG 2.jpeg", (await rig.SendAsync(path, "public.jpeg", filename: "IMG.jpeg")).SavedFilename);
        Assert.Equal("CON_.txt", (await rig.SendAsync(path, "public.plain-text", filename: "CON.txt")).SavedFilename);
        Assert.Equal("what_.txt", (await rig.SendAsync(path, "public.plain-text", filename: "what?.txt")).SavedFilename);
        Assert.Equal(["CON_.txt", "IMG 2.jpeg", "IMG.jpeg", "what_.txt"], rig.SavedFiles());
    }

    [Theory]
    [InlineData(SendFault.CorruptChunk, BridgeErrorCode.HashMismatch)]
    [InlineData(SendFault.OutOfOrder, BridgeErrorCode.ProtocolMismatch)]
    [InlineData(SendFault.CancelMid, BridgeErrorCode.TransferCanceled)]
    [InlineData(SendFault.OversizeOffer, BridgeErrorCode.SizeLimit)]
    [InlineData(SendFault.UnsafeName, BridgeErrorCode.UnsupportedFile)]
    [InlineData(SendFault.Stall, BridgeErrorCode.Timeout)]
    public async Task FaultsFailCleanly(SendFault fault, BridgeErrorCode expected)
    {
        await using var rig = new Rig();
        await rig.StartAsync();
        await rig.PairAsync();
        var path = rig.WriteFile("f.bin", 600 * 1024, out _);
        var ex = await Assert.ThrowsAsync<BridgeException>(() => rig.SendAsync(path, fault: fault));
        Assert.Equal(expected, ex.Code);
        Assert.Empty(rig.SavedFiles());
        Assert.Empty(rig.Partials());
        lock (rig.Events) Assert.Contains(rig.Events, e => e is ReceiverEvent.TransferFailed f && f.Code == expected);
    }

    [Fact]
    public async Task DeniedTypeAndExtension()
    {
        await using var rig = new Rig();
        await rig.StartAsync();
        await rig.PairAsync();
        var path = rig.WriteFile("f.bin", 10, out _);
        Assert.Equal(BridgeErrorCode.UnsupportedFile, (await Assert.ThrowsAsync<BridgeException>(() => rig.SendAsync(path, filename: "setup.exe"))).Code);
        Assert.Equal(BridgeErrorCode.UnsupportedFile, (await Assert.ThrowsAsync<BridgeException>(() => rig.SendAsync(path, "public.shell-script", filename: "run.txt"))).Code);
        Assert.Empty(rig.SavedFiles());
    }

    [Fact]
    public async Task SecondOfferDuringTransferIsBusy()
    {
        await using var rig = new Rig();
        await rig.StartAsync();
        await rig.PairAsync();
        await using var channel = await rig.Sender.OpenSessionAsync("127.0.0.1", rig.Receiver.SessionPort!.Value, rig.Peer);
        var data = RandomNumberGenerator.GetBytes(1000);
        var sha = Convert.ToHexStringLower(SHA256.HashData(data));
        TransferOffer Offer(Guid id) => new(1, id, rig.Sender.Identity.PeerID, rig.Receiver.PeerID, "a.bin", "public.data", data.Length, sha, null, 0);
        var first = Guid.NewGuid();
        await channel.SendAsync(Offer(first));
        Assert.IsType<TransferAccept>(await channel.ReceiveControlAsync(TimeSpan.FromSeconds(5)));
        var second = Guid.NewGuid();
        await channel.SendAsync(Offer(second));
        var busy = Assert.IsType<TransferReject>(await channel.ReceiveControlAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(second, busy.TransferID);
        Assert.Equal(BridgeErrorCode.ProtocolMismatch, busy.Reason);
        await channel.SendAsync(new ChunkFrame(first, 0, 0, data));
        await channel.SendAsync(new TransferComplete(first, sha, data.Length));
        Assert.IsType<TransferProgress>(await channel.ReceiveControlAsync(TimeSpan.FromSeconds(5)));
        Assert.IsType<TransferCommitted>(await channel.ReceiveControlAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task RejectedPairingStoresNothing()
    {
        await using var rig = new Rig();
        await rig.StartAsync();
        rig.Approve = false;
        var ex = await Assert.ThrowsAsync<BridgeException>(() => rig.PairAsync());
        Assert.Equal(BridgeErrorCode.PairingRejected, ex.Code);
        Assert.Empty(rig.Receiver.TrustedPeers);
        await Task.Delay(200);
        lock (rig.Events) Assert.Contains(rig.Events, e => e is ReceiverEvent.PairingFailed { Code: BridgeErrorCode.PairingRejected });
    }

    [Fact]
    public async Task RateLimitLocksAfterThreeFailures()
    {
        await using var rig = new Rig();
        await rig.StartAsync();
        rig.Approve = false;
        for (var i = 0; i < 3; i++)
        {
            await Assert.ThrowsAsync<BridgeException>(() => rig.PairAsync());
            await Task.Delay(100);
        }
        rig.Approve = true;
        var locked = await Assert.ThrowsAsync<BridgeException>(() => rig.PairAsync());
        Assert.Equal(BridgeErrorCode.PairingRejected, locked.Code);
        Assert.Empty(rig.Receiver.TrustedPeers);
    }

    [Fact]
    public async Task UnpairRevokesSessions()
    {
        await using var rig = new Rig();
        await rig.StartAsync();
        await rig.PairAsync();
        var path = rig.WriteFile("a.bin", 10, out _);
        await rig.SendAsync(path);
        Assert.Single(rig.Receiver.TrustedPeers);
        await rig.Receiver.UnpairAsync(rig.Receiver.TrustedPeers.Single().PeerID);
        var ex = await Assert.ThrowsAsync<BridgeException>(() => rig.SendAsync(path));
        Assert.Equal(BridgeErrorCode.AuthenticationFailed, ex.Code);
    }

    [Fact]
    public async Task PairingDisallowedClosesConnection()
    {
        await using var rig = new Rig();
        await rig.StartAsync();
        await rig.Receiver.SetAllowPairingAsync(false);
        await Assert.ThrowsAsync<BridgeException>(() => rig.PairAsync());
        Assert.Empty(rig.Receiver.TrustedPeers);
    }

    [Fact]
    public async Task UnavailableStopsListening()
    {
        await using var rig = new Rig();
        await rig.StartAsync();
        await rig.PairAsync();
        var port = rig.Receiver.SessionPort!.Value;
        await rig.Receiver.SetAvailableAsync(false);
        var path = rig.WriteFile("a.bin", 10, out _);
        await Assert.ThrowsAsync<BridgeException>(() => rig.Sender.SendFileAsync("127.0.0.1", port, rig.Peer, new OutgoingFile(path, "a.bin", "public.data")));
    }
}

public sealed class SessionChannelTests
{
    private static async Task<(TcpClient A, TcpClient B, TcpListener L)> Pair()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var accept = listener.AcceptTcpClientAsync();
        var a = new TcpClient();
        await a.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port);
        return (a, await accept, listener);
    }

    [Fact]
    public async Task SilentPeerIsDeclaredLost()
    {
        var (a, b, l) = await Pair();
        using var _ = b;
        await using var channel = new SessionChannel(StreamFrameTransport.Over(a), new SessionChannelOptions { KeepaliveInterval = TimeSpan.FromMilliseconds(100), DeadPeerTimeout = TimeSpan.FromMilliseconds(400) });
        channel.Start();
        var ex = await Assert.ThrowsAsync<BridgeException>(() => channel.ReceiveAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(BridgeErrorCode.PeerLost, ex.Code);
        Assert.Equal(BridgeErrorCode.PeerLost, channel.CloseReason);
        l.Stop();
    }

    [Fact]
    public async Task PingIsAnsweredAndPongRecordsRtt()
    {
        var (a, b, l) = await Pair();
        await using var left = new SessionChannel(StreamFrameTransport.Over(a), new SessionChannelOptions { KeepaliveInterval = TimeSpan.FromMilliseconds(100) });
        await using var right = new SessionChannel(StreamFrameTransport.Over(b), SessionChannelOptions.Handshake);
        left.Start();
        right.Start();
        await Task.Delay(500);
        Assert.NotNull(left.SmoothedRoundTripSeconds);
        await left.SendAsync(new TransferCancel(Guid.Empty));
        Assert.IsType<TransferCancel>(await right.ReceiveControlAsync(TimeSpan.FromSeconds(2)));
        l.Stop();
    }

    [Fact]
    public async Task OversizedFrameHeaderClosesWithE012()
    {
        var (a, b, l) = await Pair();
        await using var channel = new SessionChannel(StreamFrameTransport.Over(a), SessionChannelOptions.Handshake);
        await b.GetStream().WriteAsync(new byte[] { 0x01, 0x00, 0x01, 0x00, 0x01 });
        var ex = await Assert.ThrowsAsync<BridgeException>(() => channel.ReceiveAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(BridgeErrorCode.ProtocolMismatch, ex.Code);
        b.Dispose();
        l.Stop();
    }

    [Fact]
    public async Task InboxIsBoundedSoReadingStalls()
    {
        var (a, b, l) = await Pair();
        await using var reader = new SessionChannel(StreamFrameTransport.Over(a), SessionChannelOptions.Handshake);
        await using var writer = new SessionChannel(StreamFrameTransport.Over(b), SessionChannelOptions.Handshake);
        reader.Start();
        var chunk = new byte[512 * 1024];
        var sent = 0;
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try
        {
            while (sent < 400)
            {
                await writer.SendAsync(new ChunkFrame(Guid.Empty, (uint)sent, 0, chunk), cts.Token);
                sent++;
            }
        }
        catch (OperationCanceledException)
        {
        }
        // Inbox (8) plus kernel buffers cannot absorb 200 MiB: the sender must have been pushed back.
        Assert.True(sent < 400, $"sent {sent}");
        l.Stop();
    }
}

public sealed class NfcTests
{
    [Theory]
    [InlineData("é", "é")]
    [InlineData("각", "각")]
    [InlineData("ạ́", "ạ́")]
    [InlineData("ạ́", "ạ́")]
    [InlineData("Å", "Å")]
    [InlineData("क़", "क़")]
    [InlineData("ascii", "ascii")]
    [InlineData("\U0001F600é", "\U0001F600é")]
    public void Normalizes(string input, string expected) => Assert.Equal(expected, Text.Nfc(input));
}
