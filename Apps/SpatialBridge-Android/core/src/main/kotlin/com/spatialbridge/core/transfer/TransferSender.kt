package com.spatialbridge.core.transfer

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.ExitGesture
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.ControlMessage
import com.spatialbridge.core.model.TransferLimits
import com.spatialbridge.core.model.TransferOffer
import com.spatialbridge.core.net.Frame
import com.spatialbridge.core.session.SessionChannel
import com.spatialbridge.core.util.toHex
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException

enum class SendPhase { CREATED, OFFERED, ACCEPTED, STREAMING, VERIFYING, COMPLETED, FAILED, CANCELED }

data class SendProgress(
    val transferID: UUID,
    val phase: SendPhase,
    val bytesTransferred: Long,
    val totalBytes: Long,
    val error: BridgeErrorCode? = null,
)

typealias SendProgressHandler = (SendProgress) -> Unit

/** Fills [buffer] as far as possible (`readNBytes` needs API 33). Returns the count, 0 at EOF. */
internal fun readUpTo(input: java.io.InputStream, buffer: ByteArray): Int {
    var filled = 0
    while (filled < buffer.size) {
        val n = input.read(buffer, filled, buffer.size - filled)
        if (n < 0) break
        filled += n
    }
    return filled
}

/** Hashes and sizes files without loading them into memory. */
object FileHasher {
    suspend fun sha256Hex(file: File, chunkBytes: Int = 1 shl 20): Pair<String, Long> = withContext(Dispatchers.IO) {
        val digest = MessageDigest.getInstance("SHA-256")
        var count = 0L
        FileInputStream(file).use { input ->
            val buffer = ByteArray(chunkBytes)
            while (true) {
                currentCoroutineContext().ensureActive()
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
                count += read
            }
        }
        digest.digest().toHex() to count
    }
}

/**
 * Sends one file over an authenticated session (FR-105/106/108), like Swift's `TransferSender`:
 * hash → OFFER → ACCEPT / REJECT / replayed COMMITTED → chunks while reading PROGRESS → COMPLETE →
 * COMMITTED. Success is reported only on COMMITTED (FR-209). Cancel the calling coroutine to cancel.
 */
class TransferSender(
    private val channel: SessionChannel,
    private val localPeerID: String,
    private val remotePeerID: String,
    private val limits: TransferLimits = TransferLimits.DEFAULT,
) {
    private val busy = AtomicBoolean(false)

    suspend fun prepare(file: File): Pair<String, Long> {
        val (hex, count) = FileHasher.sha256Hex(file)
        if (count <= 0) throw BridgeException(BridgeErrorCode.UNSUPPORTED_FILE, "empty file")
        if (count > limits.maxFileBytes) throw BridgeException(BridgeErrorCode.SIZE_LIMIT, "$count bytes")
        return hex to count
    }

    /** The UTI to offer: never `dyn.*` or empty (ADR-015). */
    fun offeredContentType(filename: String, contentType: String?): String =
        contentType?.takeIf { it.isNotBlank() && !it.startsWith("dyn.") } ?: UtiMap.utiFor(filename, null)

    suspend fun send(
        file: File,
        filename: String,
        contentType: String?,
        transferID: UUID = UUID.randomUUID(),
        gesture: ExitGesture? = null,
        progress: SendProgressHandler = {},
    ): ControlMessage.Committed {
        if (!busy.compareAndSet(false, true)) throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "a transfer is already in progress")
        try {
            progress(SendProgress(transferID, SendPhase.CREATED, 0, 0))
            val (sha, count) = prepare(file)
            val type = offeredContentType(filename, contentType)
            val offer = TransferOffer(
                transferID = transferID,
                sourcePeerID = localPeerID,
                targetPeerID = remotePeerID,
                filename = FilenameSanitizer.sanitize(filename, type),
                contentType = type,
                byteCount = count,
                sha256Hex = sha,
                gesture = gesture,
                createdAtMillis = System.currentTimeMillis(),
            )
            try {
                return perform(offer, file, progress)
            } catch (e: Throwable) {
                var bridge = BridgeException.wrap(e, networkContext = true)
                if (e is CancellationException) {
                    bridge = BridgeException(BridgeErrorCode.TRANSFER_CANCELED)
                    withContext(NonCancellable) { runCatching { channel.send(ControlMessage.Cancel(transferID)) } }
                }
                val phase = if (bridge.code == BridgeErrorCode.TRANSFER_CANCELED) SendPhase.CANCELED else SendPhase.FAILED
                progress(SendProgress(transferID, phase, 0, count, bridge.code))
                throw bridge
            }
        } finally {
            busy.set(false)
        }
    }

    private suspend fun perform(offer: TransferOffer, file: File, progress: SendProgressHandler): ControlMessage.Committed {
        val total = offer.byteCount
        val id = offer.transferID
        channel.drainInbox()
        channel.send(ControlMessage.Offer(offer))
        progress(SendProgress(id, SendPhase.OFFERED, 0, total))

        val accept = when (val reply = channel.receiveControl(limits.handshakeTimeoutMillis)) {
            is ControlMessage.Accept -> reply.takeIf { it.transferID == id }
            is ControlMessage.Reject -> if (reply.transferID == id) throw BridgeException(reply.reason, "offer rejected") else null
            // Receiver already committed this ID (replayed offer): never resend bytes.
            is ControlMessage.Committed -> if (reply.transferID == id) return reply.also { progress(SendProgress(id, SendPhase.COMPLETED, total, total)) } else null
            is ControlMessage.Error -> throw BridgeException(reply.code, "receiver error")
            else -> null
        } ?: throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "expected TRANSFER_ACCEPT")
        progress(SendProgress(id, SendPhase.ACCEPTED, 0, total))

        val chunkBytes = maxOf(1, minOf(accept.chunkBytes, limits.chunkBytes, limits.maxChunkBytes))
        val tracker = Tracker(id, total, progress)
        return coroutineScope {
            val writer = launch {
                withContext(Dispatchers.IO) {
                    FileInputStream(file).use { input ->
                        var sequence = 0L
                        var offset = 0L
                        val buffer = ByteArray(chunkBytes)
                        while (true) {
                            val read = readUpTo(input, buffer)
                            if (read <= 0) break
                            currentCoroutineContext().ensureActive()
                            channel.send(Frame.Chunk(id, sequence, offset, buffer.copyOf(read)))
                            sequence = (sequence + 1) and 0xFFFF_FFFFL
                            offset += read
                            tracker.sent(offset)
                        }
                        if (offset != total) throw BridgeException(BridgeErrorCode.WRITE_FAILED, "file changed while sending")
                    }
                }
                channel.send(ControlMessage.Complete(id, offer.sha256Hex, total))
                tracker.phase(SendPhase.VERIFYING)
            }
            while (true) {
                when (val message = channel.receiveControl(limits.transferIdleTimeoutMillis * 4)) {
                    is ControlMessage.Progress -> if (message.transferID == id) tracker.acknowledged(message.acknowledgedOffset)
                    is ControlMessage.Committed -> if (message.transferID == id) {
                        writer.cancel()
                        progress(SendProgress(id, SendPhase.COMPLETED, total, total))
                        return@coroutineScope message
                    }
                    is ControlMessage.Error -> if (message.transferID == null || message.transferID == id) throw BridgeException(message.code, "receiver error")
                    is ControlMessage.Reject -> if (message.transferID == id) throw BridgeException(message.reason, "receiver rejected")
                    is ControlMessage.Cancel -> if (message.transferID == id) throw BridgeException(BridgeErrorCode.TRANSFER_CANCELED, "receiver cancelled")
                    else -> Unit
                }
            }
            @Suppress("UNREACHABLE_CODE")
            throw BridgeException(BridgeErrorCode.PEER_LOST, "no COMMITTED")
        }
    }

    /** Reports the receiver's acknowledged offset, or bytes sent until the first ack. */
    private class Tracker(val id: UUID, val total: Long, val handler: SendProgressHandler) {
        private var sent = 0L
        private var acknowledged = 0L
        private var phase = SendPhase.STREAMING

        @Synchronized fun sent(bytes: Long) { sent = bytes; emit() }
        @Synchronized fun acknowledged(bytes: Long) { acknowledged = maxOf(acknowledged, bytes); emit() }
        @Synchronized fun phase(value: SendPhase) { phase = value; emit() }

        private fun emit() = handler(SendProgress(id, phase, minOf(if (acknowledged > 0) acknowledged else sent, total), total))
    }
}
