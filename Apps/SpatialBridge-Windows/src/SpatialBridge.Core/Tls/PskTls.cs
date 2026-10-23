using System.Text;
using Org.BouncyCastle.Security;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;

namespace SpatialBridge.Core.Tls;

/// <summary>
/// Session TLS (ADR-010, ADR-013): TLS 1.2 only, TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 only,
/// no resumption, tickets or renegotiation. Identity is the initiator's peer ID as UTF-8.
/// </summary>
public static class PskTls
{
    public const int CipherSuiteId = CipherSuite.TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256;

    private static BcTlsCrypto NewCrypto() => new BcTlsCrypto(new SecureRandom());

    /// <summary>
    /// Runs the server handshake on <paramref name="transport"/>. <paramref name="lookup"/> maps an identity
    /// to its PSK, or null for unknown identities (the handshake then fails).
    /// </summary>
    public static async Task<PskTlsConnection> AcceptAsync(Stream transport, Func<string, byte[]?> lookup, TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        var manager = new IdentityManager(lookup);
        var server = new Server(NewCrypto(), manager);
        var protocol = new TlsServerProtocol(transport);
        await RunHandshake(() => protocol.Accept(server), protocol, transport, timeout, cancellationToken).ConfigureAwait(false);
        return new PskTlsConnection(protocol, manager.SelectedIdentity ?? "");
    }

    public static async Task<PskTlsConnection> ConnectAsync(Stream transport, string identity, byte[] psk, TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        ArgumentOutOfRangeException.ThrowIfNotEqual(psk.Length, 32);
        var client = new Client(NewCrypto(), new ClientIdentity(Encoding.UTF8.GetBytes(identity), (byte[])psk.Clone()));
        var protocol = new TlsClientProtocol(transport);
        await RunHandshake(() => protocol.Connect(client), protocol, transport, timeout, cancellationToken).ConfigureAwait(false);
        return new PskTlsConnection(protocol, identity);
    }

    private static async Task RunHandshake(Action handshake, TlsProtocol protocol, Stream transport, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var task = Task.Factory.StartNew(handshake, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        try
        {
            await task.WaitAsync(timeout, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            Abort(protocol, transport);
            _ = task.ContinueWith(static t => _ = t.Exception, TaskScheduler.Default);
            throw new BridgeException(BridgeErrorCode.Timeout, "TLS handshake timed out");
        }
        catch (Exception ex) when (ex is TlsFatalAlert or TlsFatalAlertReceived or TlsException or IOException or ObjectDisposedException)
        {
            Abort(protocol, transport);
            throw new BridgeException(BridgeErrorCode.AuthenticationFailed, "TLS handshake failed");
        }
    }

    private static void Abort(TlsProtocol protocol, Stream transport)
    {
        try { protocol.Close(); } catch (Exception) { }
        try { transport.Dispose(); } catch (Exception) { }
    }

    private sealed class ClientIdentity(byte[] identity, byte[] psk) : TlsPskIdentity
    {
        public void SkipIdentityHint() => Debug("no identity hint");

        public void NotifyIdentityHint(byte[] psk_identity_hint) => Debug($"identity hint [{psk_identity_hint.Length}] {Convert.ToHexString(psk_identity_hint)}");

        public byte[] GetPskIdentity() => identity;

        public byte[] GetPsk() => psk;
    }

    private sealed class IdentityManager(Func<string, byte[]?> lookup) : TlsPskIdentityManager
    {
        public string? SelectedIdentity { get; private set; }

        public byte[]? GetHint() => null;

        public byte[]? GetPsk(byte[] identity)
        {
            string text;
            try
            {
                text = new UTF8Encoding(false, true).GetString(identity);
            }
            catch (DecoderFallbackException)
            {
                return null;
            }
            var psk = lookup(text);
            if (psk is { Length: 32 })
            {
                SelectedIdentity = text;
                return (byte[])psk.Clone();
            }
            return null;
        }
    }

    private sealed class Server(TlsCrypto crypto, TlsPskIdentityManager manager) : PskTlsServer(crypto, manager)
    {
        protected override ProtocolVersion[] GetSupportedVersions() => ProtocolVersion.TLSv12.Only();

        protected override int[] GetSupportedCipherSuites() => [CipherSuiteId];

        public override TlsSession? GetSessionToResume(byte[] sessionID) => null;

        public override byte[] GetNewSessionID() => [];

        public override NewSessionTicket? GetNewSessionTicket() => null;

        // There is no certificate, so a status_request echo makes Network.framework fail with decode_error.
        protected override bool AllowCertificateStatus() => false;

        protected override bool AllowMultiCertStatus() => false;

        protected override bool AllowTrustedCAIndication() => false;

        protected override bool AllowTruncatedHmac() => false;

        public override void NotifyAlertRaised(short alertLevel, short alertDescription, string message, Exception cause) =>
            Debug($"server raised {AlertDescription.GetText(alertDescription)}: {message} {cause?.GetType().Name} {cause?.Message}");

        public override void NotifyAlertReceived(short alertLevel, short alertDescription) =>
            Debug($"server received {AlertDescription.GetText(alertDescription)}");

        public override void ProcessClientExtensions(IDictionary<int, byte[]> clientExtensions)
        {
            Debug("client extensions: " + string.Join(",", clientExtensions.Keys));
            base.ProcessClientExtensions(clientExtensions);
        }

        public override void NotifyOfferedCipherSuites(int[] offeredCipherSuites)
        {
            Debug("offered suites: " + string.Join(",", offeredCipherSuites.Select(c => c.ToString("X4", System.Globalization.CultureInfo.InvariantCulture))));
            base.NotifyOfferedCipherSuites(offeredCipherSuites);
        }
    }

    private sealed class Client(TlsCrypto crypto, TlsPskIdentity identity) : PskTlsClient(crypto, identity)
    {
        protected override ProtocolVersion[] GetSupportedVersions() => ProtocolVersion.TLSv12.Only();

        protected override int[] GetSupportedCipherSuites() => [CipherSuiteId];

        public override TlsSession? GetSessionToResume() => null;

        public override void NotifyAlertRaised(short alertLevel, short alertDescription, string message, Exception cause) =>
            Debug($"client raised {AlertDescription.GetText(alertDescription)}: {message} {cause?.Message}");

        public override void NotifyAlertReceived(short alertLevel, short alertDescription) =>
            Debug($"client received {AlertDescription.GetText(alertDescription)}");
    }

    private static readonly bool DebugEnabled = Environment.GetEnvironmentVariable("SB_TLS_DEBUG") == "1";

    private static void Debug(string message)
    {
        if (DebugEnabled) Console.Error.WriteLine("tls: " + message);
    }
}

/// <summary>An established TLS session. <see cref="Stream"/> is full-duplex safe for one reader and one writer.</summary>
public sealed class PskTlsConnection(TlsProtocol protocol, string identity) : IDisposable
{
    public string Identity { get; } = identity;

    public Stream Stream { get; } = new BlockingDuplexStream(protocol.Stream, () => { try { protocol.Close(); } catch (Exception) { } });

    public void Dispose() => Stream.Dispose();
}
