package com.spatialbridge.core.net

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.model.BridgeException
import org.bouncycastle.tls.BasicTlsPSKIdentity
import org.bouncycastle.tls.CipherSuite
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
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.security.SecureRandom
import java.util.Vector

/**
 * TLS 1.2 with an external PSK and only TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (ADR-010),
 * matching `NetworkParameters`. BouncyCastle lightweight API only: no JCA provider is registered.
 */
object PskTls {
    const val CIPHER_SUITE: Int = CipherSuite.TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256
    private val GROUPS = intArrayOf(NamedGroup.x25519, NamedGroup.secp256r1)

    private val crypto: TlsCrypto by lazy { BcTlsCrypto(SecureRandom()) }

    /** An established TLS stream. [pskIdentity] is the identity the handshake used. */
    class Connection internal constructor(
        private val socket: Socket,
        private val protocol: TlsProtocol,
        val pskIdentity: String,
    ) : AutoCloseable {
        val input: InputStream get() = protocol.inputStream
        val output: OutputStream get() = protocol.outputStream

        override fun close() {
            runCatching { protocol.close() }
            runCatching { socket.close() }
        }
    }

    /** Client handshake over a connected socket. [identity] is our own peer ID. Fails with E004. */
    fun connect(socket: Socket, identity: String, psk: ByteArray, handshakeTimeoutMillis: Int = 30_000): Connection {
        require(psk.size == 32) { "PSK must be 32 bytes" }
        val protocol = TlsClientProtocol(socket.getInputStream(), socket.getOutputStream())
        return handshake(socket, handshakeTimeoutMillis) {
            protocol.connect(Client(crypto, identity.toByteArray(Charsets.UTF_8), psk))
            Connection(socket, protocol, identity)
        }
    }

    /** Server handshake. [keyFor] maps a PSK identity (a peer ID) to its key, or null if unknown. */
    fun accept(socket: Socket, handshakeTimeoutMillis: Int = 30_000, keyFor: (String) -> ByteArray?): Connection {
        val protocol = TlsServerProtocol(socket.getInputStream(), socket.getOutputStream())
        val manager = IdentityManager(keyFor)
        return handshake(socket, handshakeTimeoutMillis) {
            protocol.accept(Server(crypto, manager))
            Connection(socket, protocol, manager.selected ?: throw IOException("no PSK identity"))
        }
    }

    private inline fun handshake(socket: Socket, timeoutMillis: Int, body: () -> Connection): Connection {
        val previous = socket.soTimeout
        try {
            socket.soTimeout = timeoutMillis
            return body().also { socket.soTimeout = previous }
        } catch (e: java.net.SocketTimeoutException) {
            runCatching { socket.close() }
            throw BridgeException(BridgeErrorCode.TIMEOUT, "TLS handshake timed out")
        } catch (e: IOException) {
            runCatching { socket.close() }
            throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "TLS handshake failed: ${e.javaClass.simpleName}")
        }
    }

    private class IdentityManager(private val keyFor: (String) -> ByteArray?) : TlsPSKIdentityManager {
        @Volatile var selected: String? = null

        override fun getHint(): ByteArray? = null

        override fun getPSK(identity: ByteArray): ByteArray? {
            val id = runCatching { Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(identity)).toString() }
                .getOrNull() ?: return null
            val key = keyFor(id)?.takeIf { it.size == 32 } ?: return null
            selected = id
            return key.copyOf()
        }
    }

    private class Client(crypto: TlsCrypto, identity: ByteArray, psk: ByteArray) :
        PSKTlsClient(crypto, BasicTlsPSKIdentity(identity, psk)) {
        override fun getSupportedVersions(): Array<ProtocolVersion> = ProtocolVersion.TLSv12.only()
        override fun getSupportedCipherSuites(): IntArray = intArrayOf(CIPHER_SUITE)
        override fun getSupportedGroups(namedGroupRoles: Vector<*>?): Vector<Int> = Vector(GROUPS.toList())
        override fun getSessionToResume(): TlsSession? = null
        override fun notifyAlertRaised(alertLevel: Short, alertDescription: Short, message: String?, cause: Throwable?) =
            debug("client raised", alertDescription, message, cause)
        override fun notifyAlertReceived(alertLevel: Short, alertDescription: Short) = debug("client received", alertDescription, null, null)
    }

    private class Server(crypto: TlsCrypto, manager: TlsPSKIdentityManager) : PSKTlsServer(crypto, manager) {
        override fun getSupportedVersions(): Array<ProtocolVersion> = ProtocolVersion.TLSv12.only()
        override fun getSupportedCipherSuites(): IntArray = intArrayOf(CIPHER_SUITE)
        override fun getSupportedGroups(): IntArray = GROUPS.copyOf()
        override fun getSessionToResume(sessionID: ByteArray?): TlsSession? = null
        override fun getNewSessionID(): ByteArray? = null

        // BoringSSL (Network.framework) rejects a status_request echo for certificate-less suites with decode_error.
        override fun allowCertificateStatus(): Boolean = false
        override fun allowMultiCertStatus(): Boolean = false
        override fun allowTrustedCAIndication(): Boolean = false
        override fun notifyAlertRaised(alertLevel: Short, alertDescription: Short, message: String?, cause: Throwable?) =
            debug("server raised", alertDescription, message, cause)
        override fun notifyAlertReceived(alertLevel: Short, alertDescription: Short) = debug("server received", alertDescription, null, null)
    }

    private fun debug(what: String, alert: Short, message: String?, cause: Throwable?) {
        if (System.getenv("SB_TLS_DEBUG") == null) return
        System.err.println("tls: $what ${org.bouncycastle.tls.AlertDescription.getText(alert)} ${message ?: ""} ${cause ?: ""}")
    }
}
