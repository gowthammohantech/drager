package com.spatialbridge.core.session

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.crypto.DeviceIdentity
import com.spatialbridge.core.crypto.EphemeralKey
import com.spatialbridge.core.crypto.PairingCrypto
import com.spatialbridge.core.crypto.PairingKeys
import com.spatialbridge.core.crypto.PairingTranscript
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.BridgeProtocol
import com.spatialbridge.core.model.ControlMessage
import com.spatialbridge.core.model.ControlMessageCoder
import com.spatialbridge.core.model.DeviceInfo
import com.spatialbridge.core.model.Hello
import com.spatialbridge.core.model.PairConfirm
import com.spatialbridge.core.model.PairRequest
import com.spatialbridge.core.model.PairResponse
import com.spatialbridge.core.model.PairingRole
import com.spatialbridge.core.model.PeerIDs
import com.spatialbridge.core.model.TrustedPeer
import com.spatialbridge.core.net.Frame
import com.spatialbridge.core.util.SecureRandomBytes
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

/** What the user compares on both screens. */
data class PairingPrompt(val shortAuthenticationString: String, val peer: DeviceInfo, val peerFingerprint: String) {
    val formattedCode: String get() = PairingCrypto.formatForDisplay(shortAuthenticationString)
}

/** A successful pairing. The caller stores [trustedPeer] and [preSharedKey]. */
class PairingOutcome(val trustedPeer: TrustedPeer, val preSharedKey: ByteArray)

/** Asks the local user to compare codes. Must return promptly when cancelled. */
typealias PairingDecisionHandler = suspend (PairingPrompt) -> Boolean

/** 3 failures per 60 s, per peer and globally (CONFORMANCE.md §4). */
class PairingRateLimiter(
    private val maxFailures: Int = 3,
    private val lockoutMillis: Long = 60_000,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private data class Entry(var count: Int = 0, var lockedUntil: Long? = null)
    private val failures = HashMap<String, Entry>()

    @Synchronized fun isLocked(key: String): Boolean {
        val until = failures[key]?.lockedUntil ?: return false
        if (now() >= until) {
            failures.remove(key)
            return false
        }
        return true
    }

    @Synchronized fun recordFailure(key: String) {
        val entry = failures.getOrPut(key) { Entry() }
        entry.count += 1
        if (entry.count >= maxFailures) {
            entry.lockedUntil = now() + lockoutMillis
            entry.count = 0
        }
    }

    @Synchronized fun recordSuccess(key: String) {
        failures.remove(key)
    }

    companion object {
        const val GLOBAL_KEY = "global"
    }
}

/**
 * The pairing handshake (PROTOCOL.md, Swift `PairingProtocol`). Trust is returned only when the local
 * user approved and the peer's confirmation verified. The channel is closed when a run returns.
 */
object PairingProtocol {
    data class Timeouts(val handshakeMillis: Long = 30_000, val userDecisionMillis: Long = 120_000)

    suspend fun runInitiator(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        timeouts: Timeouts = Timeouts(),
        decide: PairingDecisionHandler,
    ): PairingOutcome = closing(channel) { initiate(channel, identity, device, timeouts, decide) }

    suspend fun runResponder(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        rateLimiter: PairingRateLimiter,
        timeouts: Timeouts = Timeouts(),
        decide: PairingDecisionHandler,
    ): PairingOutcome = closing(channel) {
        val (theirHello, theirPayload) = expectHelloFrame(channel, Hello.PAIRING_CAPABILITY, timeouts.handshakeMillis)
        val peerID = theirHello.device.peerID
        if (rateLimiter.isLocked(peerID) || rateLimiter.isLocked(PairingRateLimiter.GLOBAL_KEY)) {
            runCatching { channel.send(ControlMessage.PairReject(BridgeErrorCode.PAIRING_REJECTED)) }
            throw BridgeException(BridgeErrorCode.PAIRING_REJECTED, "rate limited")
        }
        try {
            respond(channel, identity, device, theirHello, theirPayload, timeouts, decide).also { rateLimiter.recordSuccess(peerID) }
        } catch (e: Throwable) {
            rateLimiter.recordFailure(peerID)
            rateLimiter.recordFailure(PairingRateLimiter.GLOBAL_KEY)
            throw e
        }
    }

    private suspend fun closing(channel: SessionChannel, body: suspend () -> PairingOutcome): PairingOutcome {
        try {
            return body().also { channel.close() }
        } catch (e: Throwable) {
            channel.close(BridgeException.wrap(e, networkContext = true))
            throw e
        }
    }

    private fun pairingHello(device: DeviceInfo) =
        Hello(device = device, capabilities = listOf(Hello.PAIRING_CAPABILITY), sessionNonce = SecureRandomBytes.bytes(32))

    private suspend fun initiate(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        timeouts: Timeouts,
        decide: PairingDecisionHandler,
    ): PairingOutcome {
        val myHelloPayload = ControlMessageCoder.encode(ControlMessage.HelloMsg(pairingHello(device)))
        channel.send(Frame.Control(myHelloPayload))
        val (theirHello, theirHelloPayload) = expectHelloFrame(channel, Hello.PAIRING_CAPABILITY, timeouts.handshakeMillis)

        val ephemeral = EphemeralKey()
        val request = PairRequest(ephemeral.publicKey, identity.publicKey, device.displayName, SecureRandomBytes.bytes(32))
        channel.send(ControlMessage.PairRequestMsg(request))

        val response = when (val reply = channel.receiveControl(timeouts.handshakeMillis)) {
            is ControlMessage.PairResponseMsg -> reply.response
            is ControlMessage.PairReject -> throw BridgeException(reply.reason, "responder refused pairing")
            is ControlMessage.Error -> throw BridgeException(reply.code, "responder error")
            else -> throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "expected PAIR_RESPONSE")
        }
        if (PeerIDs.fromSigningKey(response.signingPublicKey) != theirHello.device.peerID) {
            throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "responder key does not match HELLO peer ID")
        }
        val transcript = PairingTranscript(
            initiatorHelloPayload = myHelloPayload,
            responderHelloPayload = theirHelloPayload,
            initiatorEphemeralPublicKey = request.ephemeralPublicKey,
            responderEphemeralPublicKey = response.ephemeralPublicKey,
            initiatorSigningPublicKey = identity.publicKey,
            responderSigningPublicKey = response.signingPublicKey,
            initiatorChallenge = request.challenge,
            responderChallenge = response.challenge,
        )
        val keys = PairingCrypto.derive(ephemeral, response.ephemeralPublicKey, transcript)
        if (!DeviceIdentity.verify(response.transcriptSignature, keys.transcriptHash, response.signingPublicKey)) {
            runCatching { channel.send(ControlMessage.PairReject(BridgeErrorCode.AUTHENTICATION_FAILED)) }
            throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "bad responder transcript signature")
        }
        converge(PairingRole.INITIATOR, channel, keys, identity, theirHello.device, response.signingPublicKey, timeouts, decide)
        return PairingOutcome(trusted(theirHello.device, response.signingPublicKey), keys.preSharedKey)
    }

    private suspend fun respond(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        theirHello: Hello,
        theirHelloPayload: ByteArray,
        timeouts: Timeouts,
        decide: PairingDecisionHandler,
    ): PairingOutcome {
        val myHelloPayload = ControlMessageCoder.encode(ControlMessage.HelloMsg(pairingHello(device)))
        channel.send(Frame.Control(myHelloPayload))

        val request = (channel.receiveControl(timeouts.handshakeMillis) as? ControlMessage.PairRequestMsg)?.request
            ?: throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "expected PAIR_REQUEST")
        if (PeerIDs.fromSigningKey(request.signingPublicKey) != theirHello.device.peerID) {
            runCatching { channel.send(ControlMessage.PairReject(BridgeErrorCode.AUTHENTICATION_FAILED)) }
            throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "initiator key does not match HELLO peer ID")
        }
        val ephemeral = EphemeralKey()
        val challenge = SecureRandomBytes.bytes(32)
        val transcript = PairingTranscript(
            initiatorHelloPayload = theirHelloPayload,
            responderHelloPayload = myHelloPayload,
            initiatorEphemeralPublicKey = request.ephemeralPublicKey,
            responderEphemeralPublicKey = ephemeral.publicKey,
            initiatorSigningPublicKey = request.signingPublicKey,
            responderSigningPublicKey = identity.publicKey,
            initiatorChallenge = request.challenge,
            responderChallenge = challenge,
        )
        val keys = PairingCrypto.derive(ephemeral, request.ephemeralPublicKey, transcript)
        channel.send(
            ControlMessage.PairResponseMsg(
                PairResponse(ephemeral.publicKey, identity.publicKey, device.displayName, challenge, identity.sign(keys.transcriptHash)),
            ),
        )
        converge(PairingRole.RESPONDER, channel, keys, identity, theirHello.device, request.signingPublicKey, timeouts, decide)
        return PairingOutcome(trusted(theirHello.device, request.signingPublicKey), keys.preSharedKey)
    }

    private sealed interface ConvergeEvent {
        data class Decision(val approved: Boolean) : ConvergeEvent
        class Message(val message: ControlMessage) : ConvergeEvent
        class Failure(val error: Throwable) : ConvergeEvent
    }

    /** Waits for both the local decision and the peer's confirmation, in either order. */
    private suspend fun converge(
        role: PairingRole,
        channel: SessionChannel,
        keys: PairingKeys,
        identity: DeviceIdentity,
        peer: DeviceInfo,
        peerSigningKey: ByteArray,
        timeouts: Timeouts,
        decide: PairingDecisionHandler,
    ) = withBridgeTimeout(timeouts.userDecisionMillis) {
        val prompt = PairingPrompt(keys.shortAuthenticationString, peer, PeerIDs.fingerprint(peer.peerID))
        val peerRole = if (role == PairingRole.INITIATOR) PairingRole.RESPONDER else PairingRole.INITIATOR
        val events = Channel<ConvergeEvent>(Channel.UNLIMITED)
        coroutineScope {
            val decider = launch { events.send(ConvergeEvent.Decision(decide(prompt))) }
            val reader = launch {
                while (true) {
                    val message = try {
                        channel.receiveControl()
                    } catch (e: BridgeException) {
                        events.send(ConvergeEvent.Failure(e))
                        break
                    }
                    events.send(ConvergeEvent.Message(message))
                }
            }
            var locallyApproved = false
            var peerConfirmed = false
            var confirmSendError: Throwable? = null
            try {
                while (!(locallyApproved && peerConfirmed)) {
                    when (val event = events.receive()) {
                        is ConvergeEvent.Decision -> {
                            if (!event.approved) {
                                runCatching { channel.send(ControlMessage.PairReject(BridgeErrorCode.PAIRING_REJECTED)) }
                                throw BridgeException(BridgeErrorCode.PAIRING_REJECTED, "rejected on this device")
                            }
                            locallyApproved = true
                            val confirm = PairConfirm(
                                challengeResponse = PairingCrypto.confirmation(keys.confirmKey, role, peer.peerID),
                                approvedPeerID = peer.peerID,
                                transcriptSignature = if (role == PairingRole.INITIATOR) identity.sign(keys.transcriptHash) else ByteArray(0),
                            )
                            try {
                                channel.send(ControlMessage.PairConfirmMsg(confirm))
                            } catch (e: BridgeException) {
                                // The peer may have rejected and closed first; its buffered message decides.
                                confirmSendError = e
                            }
                        }
                        is ConvergeEvent.Message -> when (val message = event.message) {
                            is ControlMessage.PairReject -> throw BridgeException(
                                if (message.reason == BridgeErrorCode.AUTHENTICATION_FAILED) BridgeErrorCode.AUTHENTICATION_FAILED else BridgeErrorCode.PAIRING_REJECTED,
                                "rejected by peer",
                            )
                            is ControlMessage.PairConfirmMsg -> {
                                val confirm = message.confirm
                                val validMac = PairingCrypto.verifyConfirmation(confirm.challengeResponse, keys.confirmKey, peerRole, identity.peerID)
                                val validSignature = peerRole == PairingRole.RESPONDER ||
                                    DeviceIdentity.verify(confirm.transcriptSignature, keys.transcriptHash, peerSigningKey)
                                if (confirm.approvedPeerID != identity.peerID || !validMac || !validSignature) {
                                    runCatching { channel.send(ControlMessage.PairReject(BridgeErrorCode.AUTHENTICATION_FAILED)) }
                                    throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "peer confirmation did not verify")
                                }
                                peerConfirmed = true
                            }
                            is ControlMessage.Error -> throw BridgeException(message.code, "peer error during pairing")
                            else -> throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "unexpected message during pairing")
                        }
                        is ConvergeEvent.Failure -> {
                            if (!peerConfirmed) throw event.error
                        }
                    }
                }
                confirmSendError?.let { throw it }
            } finally {
                decider.cancel()
                reader.cancel()
            }
        }
    }

    suspend fun expectHello(channel: SessionChannel, capability: String, timeoutMillis: Long): Hello =
        expectHelloFrame(channel, capability, timeoutMillis).first

    /** A validated HELLO and the exact payload bytes it arrived in (ADR-014). */
    suspend fun expectHelloFrame(channel: SessionChannel, capability: String, timeoutMillis: Long): Pair<Hello, ByteArray> {
        val received = channel.receiveControlFrame(timeoutMillis)
        val hello = when (val message = received.message) {
            is ControlMessage.PairReject -> throw BridgeException(message.reason, "peer refused before HELLO")
            is ControlMessage.Error -> throw BridgeException(message.code, "peer error before HELLO")
            is ControlMessage.HelloMsg -> message.hello
            else -> throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "expected HELLO, got ${message.kind.wire}")
        }
        if (hello.protocolVersion != BridgeProtocol.VERSION) {
            runCatching { channel.send(ControlMessage.Error(null, BridgeErrorCode.PROTOCOL_MISMATCH)) }
            throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "peer protocol v${hello.protocolVersion}")
        }
        if (capability !in hello.capabilities || hello.sessionNonce.size != 32) {
            throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "HELLO missing $capability")
        }
        if (!PeerIDs.isValid(hello.device.peerID)) throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "malformed peer ID")
        return hello to received.payload
    }

    private fun trusted(device: DeviceInfo, key: ByteArray) = TrustedPeer(device.peerID, device.displayName, device.platform, device.model, key)
}
