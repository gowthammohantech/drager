package com.spatialbridge.core.net

import com.spatialbridge.core.model.TransferLimits
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.channels.ClosedSendChannelException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.BufferedOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/** An ordered, bidirectional stream of frames. */
interface FrameTransport {
    /** Next frame from the peer, or null when the peer closed cleanly. Throws on failure. */
    suspend fun receive(): Frame?

    /** Sends one frame. Returns once the bytes were handed to the OS (backpressure point). */
    suspend fun send(frame: Frame)

    /** Idempotent. Unblocks a pending [receive]. */
    fun close()
}

/** Frames over blocking streams (a TCP socket or a TLS connection). */
class StreamFrameTransport(
    private val input: InputStream,
    output: OutputStream,
    private val onClose: () -> Unit,
    private val limits: TransferLimits = TransferLimits.DEFAULT,
) : FrameTransport {
    private val output = BufferedOutputStream(output, 64 * 1024)
    private val sendLock = Mutex()
    private val closed = AtomicBoolean(false)

    override suspend fun receive(): Frame? = withContext(Dispatchers.IO) {
        try {
            FrameCodec.read(input, limits)
        } catch (e: IOException) {
            if (closed.get()) null else throw e
        }
    }

    override suspend fun send(frame: Frame) {
        val bytes = FrameCodec.encode(frame, limits)
        sendLock.withLock {
            if (closed.get()) throw IOException("transport closed")
            withContext(Dispatchers.IO) {
                output.write(bytes)
                output.flush()
            }
        }
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) runCatching(onClose)
    }

    companion object {
        /** Plain TCP for the pairing handshake. */
        fun overSocket(socket: Socket, limits: TransferLimits = TransferLimits.DEFAULT) =
            StreamFrameTransport(socket.getInputStream(), socket.getOutputStream(), { socket.close() }, limits)

        fun overTls(connection: PskTls.Connection, limits: TransferLimits = TransferLimits.DEFAULT) =
            StreamFrameTransport(connection.input, connection.output, { connection.close() }, limits)
    }
}

/** Opens pairing (plain TCP) and session (TLS-PSK) connections, like `PeerConnector`. */
object PeerConnector {
    const val CONNECT_TIMEOUT_MILLIS = 10_000

    suspend fun connectSocket(endpoint: Endpoint): Socket = withContext(Dispatchers.IO) {
        val socket = Socket()
        try {
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.connect(InetSocketAddress(InetAddress.getByName(endpoint.host), endpoint.port), CONNECT_TIMEOUT_MILLIS)
            socket
        } catch (e: IOException) {
            socket.close()
            throw e
        }
    }

    suspend fun openPairing(endpoint: Endpoint, limits: TransferLimits = TransferLimits.DEFAULT): FrameTransport =
        StreamFrameTransport.overSocket(connectSocket(endpoint), limits)

    suspend fun openSession(endpoint: Endpoint, identity: String, psk: ByteArray, limits: TransferLimits = TransferLimits.DEFAULT): FrameTransport {
        val socket = connectSocket(endpoint)
        val tls = withContext(Dispatchers.IO) { PskTls.connect(socket, identity, psk) }
        return StreamFrameTransport.overTls(tls, limits)
    }
}

/** A host and port to connect to. */
data class Endpoint(val host: String, val port: Int) {
    override fun toString() = "$host:$port"
}

/** In-memory transport pair for tests. */
class MemoryFrameTransport private constructor(
    private val incoming: Channel<Frame>,
    private val outgoing: Channel<Frame>,
) : FrameTransport {
    override suspend fun receive(): Frame? = try {
        incoming.receive()
    } catch (e: ClosedReceiveChannelException) {
        null
    }

    override suspend fun send(frame: Frame) {
        try {
            outgoing.send(frame)
        } catch (e: ClosedSendChannelException) {
            throw IOException("transport closed")
        }
    }

    override fun close() {
        incoming.close()
        outgoing.close()
    }

    companion object {
        fun pair(capacity: Int = 64): Pair<MemoryFrameTransport, MemoryFrameTransport> {
            val a = Channel<Frame>(capacity)
            val b = Channel<Frame>(capacity)
            return MemoryFrameTransport(a, b) to MemoryFrameTransport(b, a)
        }
    }
}
