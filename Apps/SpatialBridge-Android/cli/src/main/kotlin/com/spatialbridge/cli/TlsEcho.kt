package com.spatialbridge.cli

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.net.PskTls
import com.spatialbridge.core.util.hexToBytesOrNull
import com.spatialbridge.core.util.pskFingerprint
import org.bouncycastle.tls.BasicTlsPSKIdentity
import org.bouncycastle.tls.NamedGroup
import org.bouncycastle.tls.PSKTlsClient
import org.bouncycastle.tls.PSKTlsServer
import org.bouncycastle.tls.ProtocolVersion
import org.bouncycastle.tls.TlsClientProtocol
import org.bouncycastle.tls.TlsPSKIdentityManager
import org.bouncycastle.tls.TlsProtocol
import org.bouncycastle.tls.TlsServerProtocol
import org.bouncycastle.tls.TlsSession
import org.bouncycastle.tls.crypto.TlsCrypto
import org.bouncycastle.tls.crypto.impl.bc.BcTlsCrypto
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.SecureRandom
import java.util.Vector
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * `tls-echo`: TLS 1.2 PSK (0xCCAC) echo server or client, for cross-stack TLS spikes.
 *
 * Test-only: `--cipher-suite HEX` (e.g. `00A8`) replaces the production [PskTls] peer with one
 * that offers (client) or accepts (server) only that suite. It exists to probe that the other
 * side refuses a downgrade (ADR-010). Never use it outside interop tests.
 */
object TlsEcho {
    /** Set by `--cipher-suite`; null means the production [PskTls] path. */
    private var suiteOverride: Int? = null

    fun run(args: Args): Int {
        val role = args.required("role")
        val identity = args.required("identity")
        val psk = args.required("psk-hex").hexToBytesOrNull()?.takeIf { it.size == 32 }
            ?: throw UsageError("--psk-hex must be 64 hex characters")
        suiteOverride = args.optional("cipher-suite")?.let { raw ->
            raw.removePrefix("0x").removePrefix("0X").toIntOrNull(16)?.takeIf { it in 0..0xFFFF }
                ?: throw UsageError("--cipher-suite must be a 16-bit hex value")
        }
        return when (role) {
            "server" -> server(args, identity, psk)
            "client" -> client(args, identity, psk)
            else -> throw UsageError("--role must be server or client")
        }
    }

    private fun server(args: Args, identity: String, psk: ByteArray): Int {
        val (host, port) = args.hostPort("listen")
        val listener = ServerSocket()
        listener.reuseAddress = true
        listener.bind(InetSocketAddress(InetAddress.getByName(host), port))
        Out.event("listening", mapOf("port" to listener.localPort, "pskFingerprint" to pskFingerprint(psk)))
        while (true) {
            val socket = listener.accept()
            thread(isDaemon = true) { echo(socket, identity, psk) }
        }
    }

    private fun echo(socket: Socket, identity: String, psk: ByteArray) {
        try {
            val suite = suiteOverride
            val tls = if (suite == null) PskTls.accept(socket) { if (it == identity) psk else null }.let(::Production)
            else SuiteProbe.accept(socket, suite, identity, psk)
            tls.use { tls ->
                Out.event("tlsEstablished", tls.details())
                val buffer = ByteArray(65536)
                while (true) {
                    val read = try { tls.input.read(buffer) } catch (e: EOFException) { -1 }
                    if (read < 0) break
                    if (read > 0) {
                        tls.output.write(buffer, 0, read)
                        tls.output.flush()
                    }
                }
                Out.event("closed")
            }
        } catch (e: BridgeException) {
            Out.error(e.code)
        } catch (e: Exception) {
            Out.error(BridgeErrorCode.PEER_LOST)
        } finally {
            runCatching { socket.close() }
        }
    }

    private fun client(args: Args, identity: String, psk: ByteArray): Int {
        val (host, port) = args.hostPort("connect")
        try {
            val socket = Socket()
            socket.connect(InetSocketAddress(InetAddress.getByName(host), port), 10_000)
            val suite = suiteOverride
            val tls = if (suite == null) Production(PskTls.connect(socket, identity, psk))
            else SuiteProbe.connect(socket, suite, identity, psk)
            tls.use { tls ->
                Out.event("tlsEstablished", tls.details())
                val ping = "ping\n".toByteArray()
                tls.output.write(ping)
                tls.output.flush()
                socket.soTimeout = 10_000
                val received = ByteArray(ping.size)
                var read = 0
                while (read < ping.size) {
                    val n = tls.input.read(received, read, ping.size - read)
                    if (n < 0) throw BridgeException(BridgeErrorCode.PEER_LOST, "eof before echo")
                    read += n
                }
                if (!received.contentEquals(ping)) throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "echo mismatch")
                Out.event("echoOk")
                return 0
            }
        } catch (e: Exception) {
            val cause = BridgeException.wrap(e, networkContext = true).code
            Out.event("error", mapOf("code" to BridgeErrorCode.AUTHENTICATION_FAILED.wire, "cause" to cause.wire))
            return 4
        }
    }
}

/** The two kinds of tls-echo stream: production [PskTls], or the test-only [SuiteProbe]. */
private interface EchoStream : AutoCloseable {
    val input: InputStream
    val output: OutputStream
    fun details(): Map<String, Any> = emptyMap()
}

private class Production(private val connection: PskTls.Connection) : EchoStream {
    override val input: InputStream get() = connection.input
    override val output: OutputStream get() = connection.output
    override fun close() = connection.close()
}

/**
 * Test-only TLS 1.2 PSK peer restricted to one caller-chosen suite (`--cipher-suite`). Used to
 * check that Drager peers refuse anything but 0xCCAC. Failures map to E004 like [PskTls].
 */
private object SuiteProbe {
    private val crypto: TlsCrypto by lazy { BcTlsCrypto(SecureRandom()) }
    private val groups = intArrayOf(NamedGroup.x25519, NamedGroup.secp256r1)

    private class Stream(private val socket: Socket, private val protocol: TlsProtocol, private val negotiated: Int) : EchoStream {
        override val input: InputStream get() = protocol.inputStream
        override val output: OutputStream get() = protocol.outputStream
        override fun details(): Map<String, Any> =
            mapOf("cipherSuite" to "%04X".format(negotiated))
        override fun close() {
            runCatching { protocol.close() }
            runCatching { socket.close() }
        }
    }

    fun connect(socket: Socket, suite: Int, identity: String, psk: ByteArray): EchoStream {
        var negotiated = -1
        val protocol = TlsClientProtocol(socket.getInputStream(), socket.getOutputStream())
        val client = object : PSKTlsClient(crypto, BasicTlsPSKIdentity(identity.toByteArray(Charsets.UTF_8), psk)) {
            override fun getSupportedVersions(): Array<ProtocolVersion> = ProtocolVersion.TLSv12.only()
            override fun getSupportedCipherSuites(): IntArray = intArrayOf(suite)
            override fun getSupportedGroups(namedGroupRoles: Vector<*>?): Vector<Int> = Vector(groups.toList())
            override fun getSessionToResume(): TlsSession? = null
            override fun notifySelectedCipherSuite(selectedCipherSuite: Int) {
                super.notifySelectedCipherSuite(selectedCipherSuite)
                negotiated = selectedCipherSuite
            }
        }
        return handshake(socket) { protocol.connect(client); Stream(socket, protocol, negotiated) }
    }

    fun accept(socket: Socket, suite: Int, identity: String, psk: ByteArray): EchoStream {
        var negotiated = -1
        val protocol = TlsServerProtocol(socket.getInputStream(), socket.getOutputStream())
        val manager = object : TlsPSKIdentityManager {
            override fun getHint(): ByteArray? = null
            override fun getPSK(id: ByteArray): ByteArray? =
                if (id.contentEquals(identity.toByteArray(Charsets.UTF_8))) psk.copyOf() else null
        }
        val server = object : PSKTlsServer(crypto, manager) {
            override fun getSupportedVersions(): Array<ProtocolVersion> = ProtocolVersion.TLSv12.only()
            override fun getSupportedCipherSuites(): IntArray = intArrayOf(suite)
            override fun getSupportedGroups(): IntArray = groups.copyOf()
            override fun getSessionToResume(sessionID: ByteArray?): TlsSession? = null
            override fun getNewSessionID(): ByteArray? = null
            override fun allowCertificateStatus(): Boolean = false
            override fun allowMultiCertStatus(): Boolean = false
            override fun allowTrustedCAIndication(): Boolean = false
            override fun getSelectedCipherSuite(): Int = super.getSelectedCipherSuite().also { negotiated = it }
        }
        return handshake(socket) { protocol.accept(server); Stream(socket, protocol, negotiated) }
    }

    private inline fun handshake(socket: Socket, body: () -> EchoStream): EchoStream {
        socket.soTimeout = 30_000
        try {
            return body().also { socket.soTimeout = 0 }
        } catch (e: IOException) {
            runCatching { socket.close() }
            throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "TLS handshake failed: ${e.javaClass.simpleName}")
        }
    }
}
