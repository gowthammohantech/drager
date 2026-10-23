package com.spatialbridge.core.session

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.ControlMessage
import com.spatialbridge.core.model.ControlMessageCoder
import com.spatialbridge.core.net.Frame
import com.spatialbridge.core.net.FrameCodec
import com.spatialbridge.core.net.FrameTransport
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException

/** Runs [block] with a deadline; a timeout becomes `BridgeException(E014)`. */
suspend fun <T> withBridgeTimeout(millis: Long, block: suspend CoroutineScope.() -> T): T = try {
    withTimeout(millis, block)
} catch (e: TimeoutCancellationException) {
    throw BridgeException(BridgeErrorCode.TIMEOUT, cause = e)
}

/**
 * Message-level view of a [FrameTransport], like Swift's `SessionChannel`. One read loop answers
 * PING, records RTT from PONG, tracks liveness and forwards everything else into a bounded inbox;
 * a slow consumer stops the read loop, which lets TCP flow control push back (ADR-007).
 */
class SessionChannel(
    val transport: FrameTransport,
    val configuration: Configuration = Configuration.SESSION,
) {
    data class Configuration(
        /** Null disables pings (pairing). */
        val keepaliveIntervalMillis: Long? = 5_000,
        val deadPeerTimeoutMillis: Long = 20_000,
        val inboxCapacity: Int = 8,
    ) {
        companion object {
            val SESSION = Configuration()
            val HANDSHAKE = Configuration(keepaliveIntervalMillis = null, deadPeerTimeoutMillis = 180_000)
        }
    }

    sealed interface Event {
        data class RoundTripTime(val seconds: Double) : Event
        data class Closed(val reason: BridgeException?) : Event
    }

    /** A decoded control message with the exact payload it came from (ADR-014). */
    class ReceivedControlFrame(val message: ControlMessage, val payload: ByteArray)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inbox = Channel<Frame>(configuration.inboxCapacity)
    private val _events = MutableSharedFlow<Event>(replay = 1, extraBufferCapacity = 16, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val events: SharedFlow<Event> = _events
    private val closedSignal = CompletableDeferred<BridgeException?>()
    private val started = AtomicBoolean(false)
    private val closing = AtomicBoolean(false)
    private var readJob: Job? = null

    @Volatile private var lastHeardNanos = System.nanoTime()
    private var pingSequence = 0L

    @Volatile var smoothedRoundTripTime: Double? = null
        private set

    @Volatile var closeReason: BridgeException? = null
        private set

    val isClosed: Boolean get() = closing.get()

    /** Starts the read loop (and keepalive if configured). Idempotent. */
    fun start() {
        if (isClosed || !started.compareAndSet(false, true)) return
        lastHeardNanos = System.nanoTime()
        readJob = scope.launch { readLoop() }
        configuration.keepaliveIntervalMillis?.let { interval -> scope.launch { keepaliveLoop(interval) } }
    }

    /** Suspends until the channel closes; returns the reason. */
    suspend fun awaitClosed(): BridgeException? = closedSignal.await()

    /** Next non-keepalive frame. Throws the close reason once closed and drained. */
    suspend fun receive(): Frame {
        start()
        return try {
            inbox.receive()
        } catch (e: ClosedReceiveChannelException) {
            throw closeReason ?: BridgeException(BridgeErrorCode.PEER_LOST, "channel closed")
        } catch (e: BridgeException) {
            throw e
        }
    }

    suspend fun receiveControlFrame(): ReceivedControlFrame {
        val frame = receive()
        if (frame !is Frame.Control) throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "unexpected chunk")
        return ReceivedControlFrame(ControlMessageCoder.decode(frame.payload), frame.payload)
    }

    suspend fun receiveControlFrame(timeoutMillis: Long): ReceivedControlFrame = withBridgeTimeout(timeoutMillis) { receiveControlFrame() }

    suspend fun receiveControl(): ControlMessage = receiveControlFrame().message

    suspend fun receiveControl(timeoutMillis: Long): ControlMessage = withBridgeTimeout(timeoutMillis) { receiveControl() }

    suspend fun send(message: ControlMessage) = send(Frame.Control(ControlMessageCoder.encode(message)))

    suspend fun send(frame: Frame) {
        if (isClosed) throw closeReason ?: BridgeException(BridgeErrorCode.PEER_LOST)
        try {
            transport.send(frame)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val bridge = BridgeException.wrap(e, networkContext = true)
            close(bridge)
            throw bridge
        }
    }

    /** Drops frames buffered from an earlier exchange. */
    fun drainInbox() {
        while (inbox.tryReceive().isSuccess) Unit
    }

    /** Closes the channel and the transport. Idempotent. */
    fun close(reason: BridgeException? = null) {
        if (!closing.compareAndSet(false, true)) return
        closeReason = reason
        inbox.close(reason ?: BridgeException(BridgeErrorCode.PEER_LOST, "closed locally"))
        transport.close()
        _events.tryEmit(Event.Closed(reason))
        closedSignal.complete(reason)
        scope.cancel()
    }

    private suspend fun readLoop() {
        try {
            while (true) {
                val frame = transport.receive() ?: break
                lastHeardNanos = System.nanoTime()
                if (frame is Frame.Control) {
                    when (val message = runCatching { ControlMessageCoder.decode(frame.payload) }.getOrNull()) {
                        is ControlMessage.Ping -> {
                            transport.send(Frame.Control(ControlMessageCoder.encode(ControlMessage.Pong(message.sequence, message.sentAtMillis))))
                            continue
                        }
                        is ControlMessage.Pong -> {
                            recordRoundTrip(message.sentAtMillis)
                            continue
                        }
                        else -> Unit
                    }
                }
                inbox.send(frame)
            }
            close(BridgeException(BridgeErrorCode.PEER_LOST, "peer closed the connection"))
        } catch (e: CancellationException) {
            return
        } catch (e: FrameCodec.CodecError) {
            close(e.toBridge())
        } catch (e: Exception) {
            if (!isClosed) close(BridgeException.wrap(e, networkContext = true))
        }
    }

    private suspend fun keepaliveLoop(intervalMillis: Long) {
        while (!isClosed) {
            delay(intervalMillis)
            if ((System.nanoTime() - lastHeardNanos) / 1_000_000 > configuration.deadPeerTimeoutMillis) {
                close(BridgeException(BridgeErrorCode.PEER_LOST, "keepalive timeout"))
                return
            }
            pingSequence = (pingSequence + 1) and 0xFFFF_FFFFL
            try {
                transport.send(Frame.Control(ControlMessageCoder.encode(ControlMessage.Ping(pingSequence))))
            } catch (e: CancellationException) {
                return
            } catch (e: Exception) {
                close(BridgeException.wrap(e, networkContext = true))
                return
            }
        }
    }

    private fun recordRoundTrip(sentAtMillis: Long) {
        val sample = (System.currentTimeMillis() - sentAtMillis) / 1000.0
        if (sample < 0 || sample >= 30) return
        val smoothed = smoothedRoundTripTime?.let { it * 0.8 + sample * 0.2 } ?: sample
        smoothedRoundTripTime = smoothed
        _events.tryEmit(Event.RoundTripTime(smoothed))
    }
}
