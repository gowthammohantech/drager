package com.spatialbridge.core.net

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.model.BridgeException
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

class PskTlsTest {
    private val identity = "0123456789abcdef0123456789abcdef"
    private val psk = ByteArray(32) { it.toByte() }

    private fun echoServer(keys: Map<String, ByteArray>): Pair<ServerSocket, CompletableFuture<String>> {
        val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        val result = CompletableFuture<String>()
        Thread {
            try {
                server.accept().use { socket ->
                    PskTls.accept(socket) { keys[it] }.use { tls ->
                        val buffer = ByteArray(5)
                        var read = 0
                        while (read < 5) read += tls.input.read(buffer, read, 5 - read)
                        tls.output.write(buffer)
                        tls.output.flush()
                        result.complete(tls.pskIdentity)
                    }
                }
            } catch (e: Throwable) {
                result.completeExceptionally(e)
            } finally {
                server.close()
            }
        }.start()
        return server to result
    }

    private fun clientEcho(port: Int, key: ByteArray, id: String = identity): ByteArray {
        val socket = Socket(InetAddress.getLoopbackAddress(), port)
        PskTls.connect(socket, id, key).use { tls ->
            tls.output.write("ping\n".toByteArray())
            tls.output.flush()
            val buffer = ByteArray(5)
            var read = 0
            while (read < 5) read += tls.input.read(buffer, read, 5 - read)
            return buffer
        }
    }

    @Test
    fun `matching PSK handshakes and echoes`() {
        val (server, result) = echoServer(mapOf(identity to psk))
        assertArrayEquals("ping\n".toByteArray(), clientEcho(server.localPort, psk))
        assertEquals(identity, result.get(10, TimeUnit.SECONDS))
    }

    @Test
    fun `wrong PSK fails with E004`() {
        val (server, result) = echoServer(mapOf(identity to psk))
        val error = assertThrows<BridgeException> { clientEcho(server.localPort, ByteArray(32) { 7 }) }
        assertEquals(BridgeErrorCode.AUTHENTICATION_FAILED, error.code)
        assertThrows<Exception> { result.get(10, TimeUnit.SECONDS) }
    }

    @Test
    fun `unknown identity fails with E004`() {
        val (server, result) = echoServer(mapOf(identity to psk))
        val error = assertThrows<BridgeException> { clientEcho(server.localPort, psk, "ffffffffffffffffffffffffffffffff") }
        assertEquals(BridgeErrorCode.AUTHENTICATION_FAILED, error.code)
        assertThrows<Exception> { result.get(10, TimeUnit.SECONDS) }
    }
}
