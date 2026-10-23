package com.spatialbridge.cli

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.DevicePlatform
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.BridgeProtocol
import com.spatialbridge.core.model.ControlMessage
import com.spatialbridge.core.model.ControlMessageCoder
import com.spatialbridge.core.model.DeviceInfo
import com.spatialbridge.core.model.TransferLimits
import com.spatialbridge.core.model.TransferOffer
import com.spatialbridge.core.model.exitCode
import com.spatialbridge.core.net.Endpoint
import com.spatialbridge.core.net.Frame
import com.spatialbridge.core.net.PeerConnector
import com.spatialbridge.core.net.StreamFrameTransport
import com.spatialbridge.core.receiver.JvmReceiverHost
import com.spatialbridge.core.session.PairingDecisionHandler
import com.spatialbridge.core.session.PairingOutcome
import com.spatialbridge.core.session.PairingProtocol
import com.spatialbridge.core.session.PairingRateLimiter
import com.spatialbridge.core.session.SessionAuthenticator
import com.spatialbridge.core.session.SessionChannel
import com.spatialbridge.core.store.FileSecretStore
import com.spatialbridge.core.store.FileTrustedPeerStore
import com.spatialbridge.core.store.IdentityStore
import com.spatialbridge.core.store.PairSecretStore
import com.spatialbridge.core.transfer.FileHasher
import com.spatialbridge.core.transfer.FilenameSanitizer
import com.spatialbridge.core.transfer.ReceiverEvent
import com.spatialbridge.core.transfer.SendPhase
import com.spatialbridge.core.transfer.TransferSender
import com.spatialbridge.core.transfer.UtiMap
import com.spatialbridge.core.util.pskFingerprint
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import java.io.File
import java.io.FileInputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.UUID

/** `--state DIR`: test-only, unencrypted `secrets.json`, `trusted-peers.json` and `staging/`. */
class CliState(path: String) {
    val directory = File(path).apply { mkdirs() }
    val secrets = FileSecretStore(File(directory, "secrets.json"))
    val identity = IdentityStore(secrets).loadOrCreate()
    val pairSecrets = PairSecretStore(secrets)
    val trusted = FileTrustedPeerStore(File(directory, "trusted-peers.json"))
    val staging = File(directory, "staging")
    val device = DeviceInfo.make(identity.peerID, "sb-jvm", DevicePlatform.ANDROID, "sb-jvm")

    suspend fun remember(outcome: PairingOutcome) {
        pairSecrets.store(outcome.preSharedKey, outcome.trustedPeer.peerID)
        trusted.upsert(outcome.trustedPeer)
    }

    /** Removes [peerID]'s pair PSK and trust entry (`unpair`). */
    suspend fun forget(peerID: String) {
        pairSecrets.remove(peerID)
        trusted.remove(peerID)
    }

    /** Peers that currently have a pair PSK on disk. */
    fun pairedPeers(): Set<String> =
        secrets.keys(BridgeProtocol.SecretKey.PAIR_PSK_PREFIX).map { it.removePrefix(BridgeProtocol.SecretKey.PAIR_PSK_PREFIX) }.toSet()
}

/**
 * `unpair --state DIR --peer PEERID`: forgets a peer. Idempotent. A `serve` on the same state reads
 * keys and trust from disk for every connection, and its [UnpairWatcher] reports the change.
 */
object Unpair {
    private val PEER_ID = Regex("^[0-9a-f]{32}$")

    fun run(args: Args): Int = runBlocking {
        val state = CliState(args.required("state"))
        val peer = args.required("peer")
        if (!PEER_ID.matches(peer)) throw UsageError("--peer must be a peer ID (32 lowercase hex characters)")
        state.forget(peer)
        Out.event("unpaired", mapOf("peerID" to peer))
        0
    }
}

/**
 * Polls the state for pair PSKs removed by another process and prints `unpaired` for each. The
 * baseline also holds every peer this process paired ([add]), so an unpair that lands between a
 * pairing and the next poll is still noticed.
 */
class UnpairWatcher(private val state: CliState) {
    private val known: MutableSet<String> = java.util.Collections.synchronizedSet(runCatching { state.pairedPeers() }.getOrDefault(emptySet()).toMutableSet())

    fun add(peerID: String) {
        known += peerID
    }

    suspend fun run() {
        while (true) {
            delay(200)
            // Snapshot before reading the disk: a local pairing writes its PSK before add(), so it is on disk.
            val snapshot = synchronized(known) { known.toSet() }
            val now = runCatching { state.pairedPeers() }.getOrNull() ?: continue
            val removed = (snapshot - now).sorted()
            synchronized(known) {
                known.removeAll(removed.toSet())
                known.addAll(now)
            }
            for (peer in removed) {
                // Keys and trust are read from disk per connection, so the next session already fails.
                runCatching { state.trusted.remove(peer) }
                Out.event("unpaired", mapOf("peerID" to peer))
            }
        }
    }
}

/** Staged partial files older than this are deleted when `serve` starts (CONFORMANCE.md §4, like `StagingArea.purge`). */
private const val STAGING_RETENTION_MILLIS = 24L * 60 * 60 * 1000

/**
 * Deletes `*.sbpart` files in [staging] whose mtime is at least [STAGING_RETENTION_MILLIS] old.
 * `JvmReceiverHost` does not purge on start, so the CLI does it like ReceiverService on Apple and .NET.
 */
private fun purgeStaging(staging: File, nowMillis: Long = System.currentTimeMillis()) {
    staging.listFiles { f -> f.isFile && f.name.endsWith(".sbpart") }?.forEach { f ->
        if (nowMillis - f.lastModified() >= STAGING_RETENTION_MILLIS) f.delete()
    }
}

/** `--test-mode` shortens timeouts like sb-swift: handshake and decision 10 s, transfer idle 5 s. */
private fun timeouts(args: Args) = if (args.flag("test-mode")) {
    PairingProtocol.Timeouts(handshakeMillis = 10_000, userDecisionMillis = 10_000)
} else {
    PairingProtocol.Timeouts()
}

private fun limits(args: Args) = if (args.flag("test-mode")) {
    TransferLimits(handshakeTimeoutMillis = 10_000, transferIdleTimeoutMillis = 5_000)
} else {
    TransferLimits()
}

private fun decider(args: Args): PairingDecisionHandler {
    val approve = when (args.optional("decision") ?: "approve") {
        "approve" -> true
        "reject" -> false
        else -> throw UsageError("--decision must be approve or reject")
    }
    return { prompt ->
        Out.event("sas", mapOf("code" to prompt.shortAuthenticationString))
        approve
    }
}

private fun paired(outcome: PairingOutcome) =
    Out.event("paired", mapOf("peerID" to outcome.trustedPeer.peerID, "pskFingerprint" to pskFingerprint(outcome.preSharedKey)))

private fun fail(event: String, error: Throwable): Int {
    val code = BridgeException.wrap(error, networkContext = true).code
    Out.event(event, mapOf("code" to code.wire))
    return code.exitCode
}

object Pairing {
    fun initiate(args: Args): Int = runBlocking {
        val state = CliState(args.required("state"))
        val (host, port) = args.hostPort("connect")
        val decide = decider(args)
        try {
            val transport = PeerConnector.openPairing(Endpoint(host, port))
            val outcome = PairingProtocol.runInitiator(
                SessionChannel(transport, SessionChannel.Configuration.HANDSHAKE), state.identity, state.device, timeouts(args), decide,
            )
            state.remember(outcome)
            paired(outcome)
            Out.event("done")
            0
        } catch (e: Exception) {
            fail("pairFailed", e)
        }
    }

    fun respond(args: Args): Int = runBlocking {
        val state = CliState(args.required("state"))
        val (host, port) = args.hostPort("listen")
        val decide = decider(args)
        val server = ServerSocket().apply {
            reuseAddress = true
            bind(InetSocketAddress(InetAddress.getByName(host), port))
        }
        Out.event("listening", mapOf("pairingPort" to server.localPort, "port" to server.localPort))
        val socket = server.accept()
        server.close()
        try {
            val outcome = PairingProtocol.runResponder(
                SessionChannel(StreamFrameTransport.overSocket(socket), SessionChannel.Configuration.HANDSHAKE),
                state.identity, state.device, PairingRateLimiter(), timeouts(args), decide,
            )
            state.remember(outcome)
            paired(outcome)
            Out.event("done")
            0
        } catch (e: Exception) {
            fail("pairFailed", e)
        }
    }
}

object Serve {
    fun run(args: Args): Int = runBlocking {
        val state = CliState(args.required("state"))
        val (host, port) = args.hostPort("listen")
        val dest = File(args.required("dest")).apply { mkdirs() }
        val sessionPort = args.optional("session-port")?.toIntOrNull() ?: 0
        val unpairs = UnpairWatcher(state)
        purgeStaging(state.staging)
        val receiver = JvmReceiverHost(
            state.identity, state.device, state.pairSecrets, state.trusted, dest, state.staging, decider(args),
            limits(args), timeouts(args),
        ) { event ->
            when (event) {
                is JvmReceiverHost.Event.Paired -> {
                    unpairs.add(event.peerID)
                    Out.event("paired", mapOf("peerID" to event.peerID, "pskFingerprint" to pskFingerprint(event.psk)))
                }
                is JvmReceiverHost.Event.PairFailed -> Out.event("pairFailed", mapOf("code" to event.code.wire))
                is JvmReceiverHost.Event.SessionReady -> Out.event("sessionReady", mapOf("peerID" to event.peerID))
                is JvmReceiverHost.Event.SessionFailed -> Out.error(event.code)
                is JvmReceiverHost.Event.Transfer -> when (val t = event.event) {
                    is ReceiverEvent.Progress -> Out.event("progress", mapOf("offset" to t.bytesReceived))
                    is ReceiverEvent.Committed -> Out.event(
                        "committed",
                        mapOf("transferID" to ControlMessageCoder.uuidString(t.offer.transferID), "byteCount" to t.offer.byteCount, "sha256Hex" to t.offer.sha256Hex),
                    )
                    is ReceiverEvent.Rejected -> Out.error(t.code)
                    is ReceiverEvent.Failed -> Out.error(t.code)
                    is ReceiverEvent.Accepted -> Unit
                }
            }
        }
        val (pairingPort, boundSession) = receiver.start(host, port, sessionPort)
        Out.event("listening", mapOf("pairingPort" to pairingPort, "sessionPort" to boundSession))
        unpairs.run()
        0
    }
}

object Send {
    private const val MIB = 1L shl 20

    fun run(args: Args): Int = runBlocking {
        val state = CliState(args.required("state"))
        val (host, port) = args.hostPort("connect")
        val file = File(args.required("file"))
        if (!file.isFile) throw UsageError("--file must be a readable file")
        val transferID = args.optional("transfer-id")?.let {
            runCatching { ControlMessageCoder.parseUuid(it) }.getOrNull() ?: throw UsageError("bad --transfer-id")
        } ?: UUID.randomUUID()
        val fault = args.optional("fault")
        if (fault != null && fault !in FAULTS) throw UsageError("unknown --fault")
        val limits = limits(args)
        try {
            val peer = args.optional("peer")?.let { state.trusted.get(it) } ?: state.trusted.all().firstOrNull()
                ?: throw BridgeException(BridgeErrorCode.NO_PEER, "no trusted peer")
            val psk = state.pairSecrets.psk(peer.peerID) ?: throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "missing pair key")
            val channel = SessionChannel(PeerConnector.openSession(Endpoint(host, port), state.identity.peerID, psk, limits))
            try {
                SessionAuthenticator.authenticateAsInitiator(channel, state.identity, state.device, peer)
                Out.event("sessionReady")
                val contentType = args.optional("content-type") ?: UtiMap.utiFor(file.name, null)
                val committed = if (fault == null) {
                    var printed = 0L
                    TransferSender(channel, state.identity.peerID, peer.peerID, limits).send(file, file.name, contentType, transferID) { p ->
                        if (p.phase == SendPhase.STREAMING && (p.bytesTransferred - printed >= MIB || (p.bytesTransferred == p.totalBytes && p.bytesTransferred > printed))) {
                            printed = p.bytesTransferred
                            Out.event("progress", mapOf("offset" to p.bytesTransferred))
                        }
                    }
                } else {
                    sendWithFault(channel, state, peer.peerID, file, contentType, transferID, fault, limits)
                }
                val sha = FileHasher.sha256Hex(file).first
                Out.event(
                    "committed",
                    mapOf("transferID" to ControlMessageCoder.uuidString(committed.transferID), "byteCount" to committed.byteCount, "sha256Hex" to sha),
                )
                Out.event("done")
                0
            } finally {
                channel.close()
            }
        } catch (e: Exception) {
            fail("error", e)
        }
    }

    private val FAULTS = setOf("corrupt-chunk", "out-of-order", "cancel-mid", "oversize-offer", "unsafe-name", "stall")

    /** Hand-built frames that bypass [TransferSender] (CONFORMANCE.md §5 faults). */
    private suspend fun sendWithFault(
        channel: SessionChannel,
        state: CliState,
        target: String,
        file: File,
        contentType: String,
        id: UUID,
        fault: String,
        limits: TransferLimits,
    ): ControlMessage.Committed {
        val (sha, count) = FileHasher.sha256Hex(file)
        val offer = TransferOffer(
            transferID = id,
            sourcePeerID = state.identity.peerID,
            targetPeerID = target,
            filename = if (fault == "unsafe-name") "../sb-unsafe.txt" else FilenameSanitizer.sanitize(file.name, contentType),
            contentType = contentType,
            byteCount = if (fault == "oversize-offer") 100L * 1024 * 1024 + 1 else count,
            sha256Hex = sha,
            gesture = null,
            createdAtMillis = System.currentTimeMillis(),
        )
        channel.send(ControlMessage.Offer(offer))
        val accept = when (val reply = channel.receiveControl(limits.handshakeTimeoutMillis)) {
            is ControlMessage.Accept -> reply
            is ControlMessage.Reject -> throw BridgeException(reply.reason, "rejected")
            is ControlMessage.Committed -> return reply
            is ControlMessage.Error -> throw BridgeException(reply.code, "receiver error")
            else -> throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "expected TRANSFER_ACCEPT")
        }
        val chunkBytes = minOf(accept.chunkBytes, limits.chunkBytes)
        val chunks = FileInputStream(file).use { input ->
            generateSequence { ByteArray(chunkBytes).let { buffer -> val n = input.read(buffer); if (n <= 0) null else buffer.copyOf(n) } }.toList()
        }
        fun chunk(index: Int, sequence: Long = index.toLong()) =
            Frame.Chunk(id, sequence, index.toLong() * chunkBytes, chunks[index])
        when (fault) {
            "corrupt-chunk" -> {
                chunks.forEachIndexed { i, _ ->
                    val frame = chunk(i)
                    if (i == 0) frame.payload[0] = (frame.payload[0].toInt() xor 0xFF).toByte()
                    channel.send(frame)
                }
                channel.send(ControlMessage.Complete(id, sha, count))
            }
            "out-of-order" -> channel.send(if (chunks.size > 1) chunk(1) else chunk(0, sequence = 1))
            "cancel-mid" -> {
                channel.send(chunk(0))
                channel.send(ControlMessage.Cancel(id))
            }
            "stall" -> Unit
        }
        while (true) {
            when (val message = channel.receiveControl(limits.transferIdleTimeoutMillis * 4)) {
                is ControlMessage.Committed -> if (message.transferID == id) return message
                is ControlMessage.Error -> throw BridgeException(message.code, "receiver error")
                is ControlMessage.Reject -> throw BridgeException(message.reason, "rejected")
                is ControlMessage.Cancel -> throw BridgeException(BridgeErrorCode.TRANSFER_CANCELED, "receiver cancelled")
                else -> Unit
            }
        }
    }
}
