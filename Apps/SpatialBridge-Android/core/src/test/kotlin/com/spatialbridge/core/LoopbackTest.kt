package com.spatialbridge.core

import com.spatialbridge.core.crypto.DeviceIdentity
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.DeviceInfo
import com.spatialbridge.core.model.TrustedPeer
import com.spatialbridge.core.net.Endpoint
import com.spatialbridge.core.net.MemoryFrameTransport
import com.spatialbridge.core.net.PeerConnector
import com.spatialbridge.core.receiver.JvmReceiverHost
import com.spatialbridge.core.service.ManualPeerLocator
import com.spatialbridge.core.service.SenderService
import com.spatialbridge.core.session.PairingProtocol
import com.spatialbridge.core.session.PairingRateLimiter
import com.spatialbridge.core.session.SessionAuthenticator
import com.spatialbridge.core.session.SessionChannel
import com.spatialbridge.core.store.InMemorySecretStore
import com.spatialbridge.core.store.InMemoryTrustedPeerStore
import com.spatialbridge.core.store.PairSecretStore
import com.spatialbridge.core.transfer.TransferSender
import com.spatialbridge.core.util.sha256
import com.spatialbridge.core.util.toHex
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.random.Random

class LoopbackTest {
    @TempDir lateinit var temp: File

    private class Side(platform: DevicePlatform, name: String) {
        val identity = DeviceIdentity.generate()
        val device = DeviceInfo.make(identity.peerID, name, platform, "test")
        val secrets = PairSecretStore(InMemorySecretStore())
        val trusted = InMemoryTrustedPeerStore()
    }

    private fun receiverHost(receiver: Side, events: MutableList<JvmReceiverHost.Event>, approve: Boolean = true): Pair<JvmReceiverHost, Pair<Int, Int>> {
        val dest = File(temp, "dest").apply { mkdirs() }
        val host = JvmReceiverHost(receiver.identity, receiver.device, receiver.secrets, receiver.trusted, dest, File(temp, "staging"), { approve }) {
            events += it
        }
        return host to host.start("127.0.0.1")
    }

    @Test
    fun `pair, TLS session, session auth, 1 MiB file, COMMITTED`() = runBlocking {
        val phone = Side(DevicePlatform.ANDROID, "Pixel")
        val computer = Side(DevicePlatform.WINDOWS, "Desk PC")
        val events = CopyOnWriteArrayList<JvmReceiverHost.Event>()
        val (host, ports) = receiverHost(computer, events)
        host.use {
            val locator = ManualPeerLocator()
            locator.add("manual:test", "Desk PC", pairing = Endpoint("127.0.0.1", ports.first), session = Endpoint("127.0.0.1", ports.second))
            val service = SenderService(phone.identity, phone.device, phone.secrets, phone.trusted, locator)
            service.startDiscovery()
            withTimeout(20_000) {
                coroutineScope {
                    val pairing = async { service.pair("manual:test") }
                    service.pairing.first { it is PairingState.CompareCode }
                    service.answerPairing(true)
                    pairing.await()
                }
            }
            assertEquals(PairingState.Paired(computer.identity.peerID), service.pairing.value)
            assertTrue(service.peers.value.single().isTrusted)
            // The receiver persists its side right after its own confirmation, possibly after ours.
            withTimeout(5_000) { while (events.none { it is JvmReceiverHost.Event.Paired }) kotlinx.coroutines.delay(10) }
            assertArrayEquals(phone.secrets.psk(computer.identity.peerID), computer.secrets.psk(phone.identity.peerID))

            val bytes = Random(7).nextBytes(1 shl 20)
            val source = File(temp, "upload.bin").apply { writeBytes(bytes) }
            val states = CopyOnWriteArrayList<TransferState>()
            val collector = launch { service.transfer.collect { states += it } }
            withTimeout(30_000) {
                service.send(OutgoingFile(source.path, "photo.bin", "public.data", bytes.size.toLong()), null)
            }
            collector.cancel()
            val final = service.transfer.value
            assertEquals(TransferState.Committed("photo.bin", bytes.size.toLong()), final)
            assertTrue(states.none { it is TransferState.Committed } || states.last() is TransferState.Committed)
            val saved = File(temp, "dest/photo.bin")
            assertEquals(sha256(bytes).toHex(), sha256(saved.readBytes()).toHex())
            assertTrue(File(temp, "staging").listFiles().isNullOrEmpty())
            assertTrue(events.any { it is JvmReceiverHost.Event.SessionReady && it.peerID == phone.identity.peerID })
            service.stopDiscovery()
        }
    }

    @Test
    fun `rejected pairing fails with E003 on both sides`() = runBlocking {
        val (a, b) = MemoryFrameTransport.pair()
        val initiator = Side(DevicePlatform.ANDROID, "A")
        val responder = Side(DevicePlatform.MACOS, "B")
        coroutineScope {
            val r = async {
                runCatching {
                    PairingProtocol.runResponder(SessionChannel(b, SessionChannel.Configuration.HANDSHAKE), responder.identity, responder.device, PairingRateLimiter()) { false }
                }
            }
            val i = runCatching {
                PairingProtocol.runInitiator(SessionChannel(a, SessionChannel.Configuration.HANDSHAKE), initiator.identity, initiator.device) { true }
            }
            assertEquals(BridgeErrorCode.PAIRING_REJECTED, (i.exceptionOrNull() as BridgeException).code)
            assertEquals(BridgeErrorCode.PAIRING_REJECTED, (r.await().exceptionOrNull() as BridgeException).code)
        }
    }

    @Test
    fun `both sides derive the same SAS and PSK`() = runBlocking {
        val (a, b) = MemoryFrameTransport.pair()
        val initiator = Side(DevicePlatform.ANDROID, "Zoë’s Pixel")
        val responder = Side(DevicePlatform.WINDOWS, "Bürö PC")
        var iCode = ""
        var rCode = ""
        coroutineScope {
            val r = async {
                PairingProtocol.runResponder(SessionChannel(b, SessionChannel.Configuration.HANDSHAKE), responder.identity, responder.device, PairingRateLimiter()) {
                    rCode = it.shortAuthenticationString
                    true
                }
            }
            val i = PairingProtocol.runInitiator(SessionChannel(a, SessionChannel.Configuration.HANDSHAKE), initiator.identity, initiator.device) {
                iCode = it.shortAuthenticationString
                true
            }
            val rr = r.await()
            assertEquals(iCode, rCode)
            assertArrayEquals(i.preSharedKey, rr.preSharedKey)
            assertEquals(responder.identity.peerID, i.trustedPeer.peerID)
            assertEquals(initiator.identity.peerID, rr.trustedPeer.peerID)
        }
    }

    @Test
    fun `replayed transfer ID returns COMMITTED without resending, wrong key fails E004`() = runBlocking {
        val phone = Side(DevicePlatform.ANDROID, "Pixel")
        val computer = Side(DevicePlatform.MACOS, "Mac")
        val events = CopyOnWriteArrayList<JvmReceiverHost.Event>()
        val (host, ports) = receiverHost(computer, events)
        host.use {
            val psk = Random.nextBytes(32)
            phone.secrets.store(psk, computer.identity.peerID)
            computer.secrets.store(psk, phone.identity.peerID)
            phone.trusted.upsert(TrustedPeer(computer.identity.peerID, "Mac", DevicePlatform.MACOS, "m", computer.identity.publicKey))
            computer.trusted.upsert(TrustedPeer(phone.identity.peerID, "Pixel", DevicePlatform.ANDROID, "p", phone.identity.publicKey))
            val target = phone.trusted.all().single()

            suspend fun session(key: ByteArray): SessionChannel {
                val channel = SessionChannel(PeerConnector.openSession(Endpoint("127.0.0.1", ports.second), phone.identity.peerID, key))
                SessionAuthenticator.authenticateAsInitiator(channel, phone.identity, phone.device, target)
                return channel
            }
            val source = File(temp, "a.txt").apply { writeText("hello") }
            val id = UUID.randomUUID()
            val first = session(psk)
            val committed = TransferSender(first, phone.identity.peerID, target.peerID).send(source, "a.txt", "public.plain-text", id)
            first.close()
            val second = session(psk)
            val replay = TransferSender(second, phone.identity.peerID, target.peerID).send(source, "a.txt", "public.plain-text", id)
            second.close()
            assertEquals(committed, replay)
            assertEquals(1, File(temp, "dest").listFiles()!!.size)
            assertEquals(1, events.count { it is JvmReceiverHost.Event.Transfer && it.event is com.spatialbridge.core.transfer.ReceiverEvent.Committed })

            val error = assertThrows<BridgeException> { runBlocking { session(Random.nextBytes(32)) } }
            assertEquals(BridgeErrorCode.AUTHENTICATION_FAILED, error.code)
        }
    }
}
