package com.spatialbridge.core.transfer

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.BridgeProtocol
import com.spatialbridge.core.model.ControlMessage
import com.spatialbridge.core.model.ControlMessageCoder
import com.spatialbridge.core.model.TransferLimits
import com.spatialbridge.core.model.TransferOffer
import com.spatialbridge.core.model.TrustedPeer
import com.spatialbridge.core.net.Frame
import com.spatialbridge.core.session.SessionChannel
import com.spatialbridge.core.session.withBridgeTimeout
import com.spatialbridge.core.util.toHex
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Terminal outcomes by transfer ID, so a replayed offer never creates a second file. */
class TransferOutcomeLedger {
    sealed interface Outcome {
        data class Committed(val savedFilename: String, val byteCount: Long) : Outcome
        data class Failed(val code: BridgeErrorCode) : Outcome
    }

    private val outcomes = ConcurrentHashMap<UUID, Outcome>()
    fun outcome(id: UUID): Outcome? = outcomes[id]
    fun record(id: UUID, outcome: Outcome) { outcomes[id] = outcome }
}

sealed interface ReceiverEvent {
    data class Accepted(val offer: TransferOffer) : ReceiverEvent
    data class Progress(val transferID: UUID, val bytesReceived: Long, val totalBytes: Long) : ReceiverEvent
    data class Committed(val offer: TransferOffer, val saved: File) : ReceiverEvent
    data class Rejected(val offer: TransferOffer, val code: BridgeErrorCode) : ReceiverEvent
    data class Failed(val offer: TransferOffer, val code: BridgeErrorCode) : ReceiverEvent
}

/**
 * Minimal receiver for JVM self-tests and `sb-jvm serve` (the product receivers are macOS and
 * Windows). Mirrors Swift's `TransferReceiver`: validate → ACCEPT → strict chunks into a staging
 * file with incremental SHA-256 → COMPLETE → verify → fsync → exclusive collision-safe move →
 * COMMITTED. Every failure removes the staging file.
 */
class TransferReceiver(
    private val channel: SessionChannel,
    private val peer: TrustedPeer,
    private val localPeerID: String,
    private val destination: File,
    private val staging: File,
    private val ledger: TransferOutcomeLedger,
    private val limits: TransferLimits = TransferLimits.DEFAULT,
    private val progressAckInterval: Long = 1L shl 20,
    private val emit: (ReceiverEvent) -> Unit = {},
) {
    /** Serves offers until the session closes. Never throws. */
    suspend fun run() {
        while (true) {
            val message = try {
                channel.receiveControl()
            } catch (e: BridgeException) {
                return
            }
            when (message) {
                is ControlMessage.Offer -> handle(message.offer)
                is ControlMessage.Cancel, is ControlMessage.Complete, is ControlMessage.Progress -> Unit
                else -> runCatching { channel.send(ControlMessage.Error(message.transferID, BridgeErrorCode.PROTOCOL_MISMATCH)) }
            }
        }
    }

    private suspend fun handle(offer: TransferOffer) {
        (ledger.outcome(offer.transferID) as? TransferOutcomeLedger.Outcome.Committed)?.let {
            runCatching { channel.send(ControlMessage.Committed(offer.transferID, it.savedFilename, it.byteCount)) }
            return
        }
        try {
            validate(offer)
        } catch (e: BridgeException) {
            ledger.record(offer.transferID, TransferOutcomeLedger.Outcome.Failed(e.code))
            runCatching { channel.send(ControlMessage.Reject(offer.transferID, e.code)) }
            emit(ReceiverEvent.Rejected(offer, e.code))
            return
        }
        try {
            channel.send(ControlMessage.Accept(offer.transferID, minOf(limits.chunkBytes, limits.maxChunkBytes)))
        } catch (e: BridgeException) {
            return
        }
        emit(ReceiverEvent.Accepted(offer))
        val part = File(staging, "${offer.transferID}.sbpart")
        try {
            val saved = receive(offer, part)
            ledger.record(offer.transferID, TransferOutcomeLedger.Outcome.Committed(saved.name, offer.byteCount))
            emit(ReceiverEvent.Committed(offer, saved))
            runCatching { channel.send(ControlMessage.Committed(offer.transferID, saved.name, offer.byteCount)) }
        } catch (e: Exception) {
            val bridge = BridgeException.wrap(e, networkContext = true)
            part.delete()
            ledger.record(offer.transferID, TransferOutcomeLedger.Outcome.Failed(bridge.code))
            if (!channel.isClosed) runCatching { channel.send(ControlMessage.Error(offer.transferID, bridge.code)) }
            emit(ReceiverEvent.Failed(offer, bridge.code))
        }
    }

    private fun validate(offer: TransferOffer) {
        fun fail(code: BridgeErrorCode, detail: String): Nothing = throw BridgeException(code, detail)
        if (offer.sourcePeerID != peer.peerID) fail(BridgeErrorCode.AUTHENTICATION_FAILED, "offer source does not match session peer")
        if (offer.targetPeerID != localPeerID) fail(BridgeErrorCode.AUTHENTICATION_FAILED, "offer addressed to another device")
        if (offer.protocolVersion != BridgeProtocol.VERSION) fail(BridgeErrorCode.PROTOCOL_MISMATCH, "offer version")
        if (offer.byteCount <= 0) fail(BridgeErrorCode.UNSUPPORTED_FILE, "empty file")
        if (offer.byteCount > limits.maxFileBytes) fail(BridgeErrorCode.SIZE_LIMIT, "too large")
        if (offer.sha256Hex.length != 64 || offer.sha256Hex.any { Character.digit(it, 16) < 0 }) fail(BridgeErrorCode.PROTOCOL_MISMATCH, "bad digest")
        if (!UtiMap.allowedOnReceiver(offer.filename, offer.contentType)) fail(BridgeErrorCode.UNSUPPORTED_FILE, "policy")
        if (!destination.isDirectory || !destination.canWrite()) fail(BridgeErrorCode.DESTINATION_PERMISSION_EXPIRED, "destination")
        if (destination.usableSpace < offer.byteCount + limits.diskHeadroomBytes) fail(BridgeErrorCode.INSUFFICIENT_STORAGE, "free space")
    }

    private suspend fun receive(offer: TransferOffer, part: File): File {
        staging.mkdirs()
        val digest = MessageDigest.getInstance("SHA-256")
        var written = 0L
        var expectedSequence = 0L
        var lastAck = 0L
        var complete: ControlMessage.Complete? = null
        val output = withContext(Dispatchers.IO) { FileOutputStream(part) }
        output.use { out ->
            while (complete == null) {
                when (val frame = withBridgeTimeout(limits.transferIdleTimeoutMillis) { channel.receive() }) {
                    is Frame.Chunk -> {
                        if (frame.transferID != offer.transferID) throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "chunk for another transfer")
                        if (frame.sequence != expectedSequence || frame.offset != written) throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "out-of-order chunk")
                        if (written + frame.payload.size > offer.byteCount) throw BridgeException(BridgeErrorCode.HASH_MISMATCH, "more bytes than offered")
                        withContext(Dispatchers.IO) { out.write(frame.payload) }
                        digest.update(frame.payload)
                        written += frame.payload.size
                        expectedSequence = (expectedSequence + 1) and 0xFFFF_FFFFL
                        if (written - lastAck >= progressAckInterval || written == offer.byteCount) {
                            lastAck = written
                            channel.send(ControlMessage.Progress(offer.transferID, written))
                            emit(ReceiverEvent.Progress(offer.transferID, written, offer.byteCount))
                        }
                    }
                    is Frame.Control -> when (val message = ControlMessageCoder.decode(frame.payload)) {
                        is ControlMessage.Complete -> if (message.transferID == offer.transferID) complete = message else throw unexpected(message)
                        is ControlMessage.Cancel -> if (message.transferID == offer.transferID) throw BridgeException(BridgeErrorCode.TRANSFER_CANCELED, "sender cancelled") else throw unexpected(message)
                        is ControlMessage.Error -> throw BridgeException(message.code, "sender error")
                        is ControlMessage.Offer -> runCatching { channel.send(ControlMessage.Reject(message.offer.transferID, BridgeErrorCode.PROTOCOL_MISMATCH, "busy")) }
                        else -> throw unexpected(message)
                    }
                }
            }
            withContext(Dispatchers.IO) {
                out.flush()
                out.fd.sync()
            }
        }
        val hex = digest.digest().toHex()
        val done = complete!!
        if (written != offer.byteCount || done.byteCount != offer.byteCount || hex != offer.sha256Hex.lowercase() || done.sha256Hex.lowercase() != hex) {
            throw BridgeException(BridgeErrorCode.HASH_MISMATCH, "size or digest mismatch")
        }
        return commit(part, offer.filename)
    }

    private fun unexpected(message: ControlMessage) = BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "unexpected ${message.kind.wire} during transfer")

    /** Exclusive move with `name 2.ext` collision naming. Never overwrites. */
    private suspend fun commit(part: File, suggestedName: String): File = withContext(Dispatchers.IO) {
        for (attempt in 1..1000) {
            val target = File(destination, FilenameSanitizer.candidate(suggestedName, attempt))
            try {
                Files.move(part.toPath(), target.toPath())
                return@withContext target
            } catch (e: FileAlreadyExistsException) {
                continue
            }
        }
        throw BridgeException(BridgeErrorCode.WRITE_FAILED, "no free name")
    }
}
