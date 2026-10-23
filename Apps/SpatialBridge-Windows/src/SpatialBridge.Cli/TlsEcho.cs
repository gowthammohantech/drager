using System.Net;
using System.Net.Sockets;
using System.Text;
using SpatialBridge.Core;
using SpatialBridge.Core.Tls;

namespace SpatialBridge.Cli;

/// <summary><c>tls-echo</c>: the session TLS profile as a bare echo server or client, for cross-stack spikes.</summary>
internal static class TlsEcho
{
    public static async Task<int> RunAsync(Args args)
    {
        var role = args.Required("role");
        var identity = args.Required("identity");
        var psk = Hex.TryDecode(args.Required("psk-hex"));
        if (psk is not { Length: 32 }) throw new UsageException("--psk-hex must be 64 hex characters");
        return role switch
        {
            "server" => await ServerAsync(args, identity, psk),
            "client" => await ClientAsync(args, identity, psk),
            _ => throw new UsageException("--role must be server or client"),
        };
    }

    private static async Task<int> ServerAsync(Args args, string identity, byte[] psk)
    {
        var (host, port) = args.HostPort("listen");
        using var listener = new TcpListener(IPAddress.Parse(host), port);
        listener.Start();
        Out.Event("listening", ("port", ((IPEndPoint)listener.LocalEndpoint).Port), ("pskFingerprint", Out.PskFingerprint(psk)));
        while (true)
        {
            var socket = await listener.AcceptTcpClientAsync();
            _ = Task.Run(() => EchoAsync(socket, identity, psk));
        }
    }

    private static async Task EchoAsync(TcpClient socket, string identity, byte[] psk)
    {
        using var _ = socket;
        socket.NoDelay = true;
        try
        {
            using var tls = await PskTls.AcceptAsync(socket.GetStream(), id => id == identity ? psk : null, TimeSpan.FromSeconds(30));
            Out.Event("tlsEstablished");
            var buffer = new byte[16 * 1024];
            while (true)
            {
                int n;
                try
                {
                    n = await tls.Stream.ReadAsync(buffer);
                }
                catch (IOException)
                {
                    break;
                }
                if (n <= 0) break;
                await tls.Stream.WriteAsync(buffer.AsMemory(0, n));
            }
            Out.Event("closed");
        }
        catch (BridgeException ex)
        {
            Out.Error(ex.Code);
        }
    }

    private static async Task<int> ClientAsync(Args args, string identity, byte[] psk)
    {
        var (host, port) = args.HostPort("connect");
        try
        {
            using var socket = new TcpClient { NoDelay = true };
            await socket.ConnectAsync(host, port).WaitAsync(TimeSpan.FromSeconds(10));
            using var tls = await PskTls.ConnectAsync(socket.GetStream(), identity, psk, TimeSpan.FromSeconds(30));
            Out.Event("tlsEstablished");
            var ping = Encoding.UTF8.GetBytes("ping\n");
            await tls.Stream.WriteAsync(ping);
            var received = new byte[ping.Length];
            var have = 0;
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            while (have < ping.Length)
            {
                var n = await tls.Stream.ReadAsync(received.AsMemory(have)).AsTask().WaitAsync(cts.Token);
                if (n <= 0) throw new BridgeException(BridgeErrorCode.PeerLost, "eof before echo");
                have += n;
            }
            if (!received.AsSpan().SequenceEqual(ping)) throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "echo mismatch");
            Out.Event("echoOk");
            return 0;
        }
        catch (Exception ex) when (ex is not UsageException)
        {
            Out.Event("error", ("code", BridgeErrorCode.AuthenticationFailed.ToWire()), ("cause", BridgeException.Classify(ex, true).ToWire()));
            return 4;
        }
    }
}
