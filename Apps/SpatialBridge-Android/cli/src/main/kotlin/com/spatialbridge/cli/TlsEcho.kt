package com.spatialbridge.cli

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.net.PskTls
import com.spatialbridge.core.util.hexToBytesOrNull
import com.spatialbridge.core.util.pskFingerprint
import java.io.EOFException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/** `tls-echo`: TLS 1.2 PSK (0xCCAC) echo server or client, for cross-stack TLS spikes. */
object TlsEcho {
    fun run(args: Args): Int {
        val role = args.required("role")
        val identity = args.required("identity")
        val psk = args.required("psk-hex").hexToBytesOrNull()?.takeIf { it.size == 32 }
            ?: throw UsageError("--psk-hex must be 64 hex characters")
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
            PskTls.accept(socket) { if (it == identity) psk else null }.use { tls ->
                Out.event("tlsEstablished")
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
            PskTls.connect(socket, identity, psk).use { tls ->
                Out.event("tlsEstablished")
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
