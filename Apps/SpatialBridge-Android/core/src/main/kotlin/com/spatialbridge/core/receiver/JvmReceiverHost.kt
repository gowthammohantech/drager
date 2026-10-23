package com.spatialbridge.core.receiver

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.crypto.DeviceIdentity
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.DeviceInfo
import com.spatialbridge.core.model.TransferLimits
import com.spatialbridge.core.net.PskTls
import com.spatialbridge.core.net.StreamFrameTransport
import com.spatialbridge.core.session.PairingDecisionHandler
import com.spatialbridge.core.session.PairingProtocol
import com.spatialbridge.core.session.PairingRateLimiter
import com.spatialbridge.core.session.SessionAuthenticator
import com.spatialbridge.core.session.SessionChannel
import com.spatialbridge.core.store.PairSecretStore
import com.spatialbridge.core.store.TrustedPeerStore
import com.spatialbridge.core.transfer.ReceiverEvent
import com.spatialbridge.core.transfer.TransferOutcomeLedger
import com.spatialbridge.core.transfer.TransferReceiver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * A receiver for JVM self-tests and `sb-jvm serve`: a plain-TCP pairing listener and a TLS-PSK
 * session listener, no discovery. The product receivers are the macOS and Windows apps.
 */
class JvmReceiverHost(
    private val identity: DeviceIdentity,
    private val device: DeviceInfo,
    private val pairSecrets: PairSecretStore,
    private val trustedPeers: TrustedPeerStore,
    private val destination: File,
    private val staging: File,
    private val decide: PairingDecisionHandler,
    private val limits: TransferLimits = TransferLimits.DEFAULT,
    private val timeouts: PairingProtocol.Timeouts = PairingProtocol.Timeouts(),
    private val onEvent: (Event) -> Unit = {},
) : AutoCloseable {
    sealed interface Event {
        data class Paired(val peerID: String, val psk: ByteArray) : Event
        data class PairFailed(val code: BridgeErrorCode) : Event
        data class SessionReady(val peerID: String) : Event
        data class SessionFailed(val code: BridgeErrorCode) : Event
        data class Transfer(val event: ReceiverEvent) : Event
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val rateLimiter = PairingRateLimiter()
    private val ledger = TransferOutcomeLedger()
    private val pairingLock = Mutex()
    private val sockets = ArrayList<ServerSocket>()

    /** Binds both listeners and returns `(pairingPort, sessionPort)`. */
    fun start(host: String, pairingPort: Int = 0, sessionPort: Int = 0): Pair<Int, Int> {
        val pairing = bind(host, pairingPort)
        val session = bind(host, sessionPort)
        scope.launch { acceptLoop(pairing) { handlePairing(it) } }
        scope.launch { acceptLoop(session) { handleSession(it) } }
        return pairing.localPort to session.localPort
    }

    private fun bind(host: String, port: Int) = ServerSocket().apply {
        reuseAddress = true
        bind(InetSocketAddress(InetAddress.getByName(host), port))
        synchronized(sockets) { sockets += this }
    }

    private suspend fun acceptLoop(server: ServerSocket, handle: suspend (Socket) -> Unit) {
        while (scope.isActive) {
            val socket = runCatching { withContext(Dispatchers.IO) { server.accept() } }.getOrNull() ?: return
            socket.tcpNoDelay = true
            scope.launch { handle(socket) }
        }
    }

    private suspend fun handlePairing(socket: Socket) = pairingLock.withLock {
        try {
            val channel = SessionChannel(StreamFrameTransport.overSocket(socket, limits), SessionChannel.Configuration.HANDSHAKE)
            val outcome = PairingProtocol.runResponder(channel, identity, device, rateLimiter, timeouts, decide)
            pairSecrets.store(outcome.preSharedKey, outcome.trustedPeer.peerID)
            trustedPeers.upsert(outcome.trustedPeer)
            onEvent(Event.Paired(outcome.trustedPeer.peerID, outcome.preSharedKey))
        } catch (e: Exception) {
            onEvent(Event.PairFailed(BridgeException.wrap(e, networkContext = true).code))
        } finally {
            runCatching { socket.close() }
        }
    }

    private suspend fun handleSession(socket: Socket) {
        val channel = try {
            val tls = withContext(Dispatchers.IO) { PskTls.accept(socket) { id -> pairSecrets.psk(id) } }
            val channel = SessionChannel(StreamFrameTransport.overTls(tls, limits), SessionChannel.Configuration.SESSION)
            val (peer, _) = try {
                SessionAuthenticator.authenticateAsResponder(channel, identity, device, { trustedPeers.get(it) })
            } catch (e: Exception) {
                channel.close(BridgeException.wrap(e, networkContext = true))
                throw e
            }
            // The TLS identity must be the peer that authenticated.
            if (peer.peerID != tls.pskIdentity) {
                channel.close()
                throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "PSK identity does not match session peer")
            }
            onEvent(Event.SessionReady(peer.peerID))
            channel to peer
        } catch (e: Exception) {
            runCatching { socket.close() }
            onEvent(Event.SessionFailed(BridgeException.wrap(e, networkContext = true).code))
            return
        }
        val (session, peer) = channel
        TransferReceiver(session, peer, identity.peerID, destination, staging, ledger, limits) { onEvent(Event.Transfer(it)) }.run()
        session.close()
    }

    override fun close() {
        synchronized(sockets) { sockets.forEach { runCatching { it.close() } } }
        scope.cancel()
    }
}
