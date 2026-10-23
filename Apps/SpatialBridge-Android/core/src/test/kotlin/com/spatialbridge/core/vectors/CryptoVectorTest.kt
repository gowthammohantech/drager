package com.spatialbridge.core.vectors

import com.spatialbridge.core.crypto.DeviceIdentity
import com.spatialbridge.core.crypto.EphemeralKey
import com.spatialbridge.core.crypto.PairingCrypto
import com.spatialbridge.core.crypto.PairingTranscript
import com.spatialbridge.core.crypto.SessionContext
import com.spatialbridge.core.model.ControlMessage
import com.spatialbridge.core.model.ControlMessageCoder
import com.spatialbridge.core.model.PairingRole
import com.spatialbridge.core.model.PeerIDs
import com.spatialbridge.core.util.hexToBytes
import com.spatialbridge.core.util.pskFingerprint
import com.spatialbridge.core.util.toHex
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.TestFactory

class CryptoVectorTest {
    @TestFactory
    fun pairing() = Vectors.tests("pairing") { c ->
        val initiator = DeviceIdentity(c.str("initiatorSigningSeed").hexToBytes())
        val responder = DeviceIdentity(c.str("responderSigningSeed").hexToBytes())
        assertEquals(c.str("initiatorSigningPublicKey"), initiator.publicKey.toHex())
        assertEquals(c.str("responderSigningPublicKey"), responder.publicKey.toHex())
        assertEquals(c.str("initiatorPeerID"), initiator.peerID)
        assertEquals(c.str("responderPeerID"), responder.peerID)

        val iEph = EphemeralKey(c.str("initiatorEphemeralPrivateKey").hexToBytes())
        val rEph = EphemeralKey(c.str("responderEphemeralPrivateKey").hexToBytes())
        assertEquals(c.str("initiatorEphemeralPublicKey"), iEph.publicKey.toHex())
        assertEquals(c.str("responderEphemeralPublicKey"), rEph.publicKey.toHex())
        assertEquals(c.str("sharedSecret"), iEph.sharedSecret(rEph.publicKey).toHex())
        assertEquals(c.str("sharedSecret"), rEph.sharedSecret(iEph.publicKey).toHex())

        // The HELLO bytes Kotlin would send re-encode to exactly the Swift bytes.
        for (side in listOf("initiatorHello", "responderHello")) {
            val bytes = c.str(side).hexToBytes()
            assertEquals(c.str(side + "Json"), String(bytes))
            val hello = ControlMessageCoder.decode(bytes) as ControlMessage.HelloMsg
            assertEquals(c.str(side), ControlMessageCoder.encode(hello).toHex())
        }
        val iHello = (ControlMessageCoder.decode(c.str("initiatorHello").hexToBytes()) as ControlMessage.HelloMsg).hello
        val rHello = (ControlMessageCoder.decode(c.str("responderHello").hexToBytes()) as ControlMessage.HelloMsg).hello
        assertEquals(c.str("initiatorNonce"), iHello.sessionNonce.toHex())
        assertEquals(c.str("responderNonce"), rHello.sessionNonce.toHex())

        val transcript = PairingTranscript(
            c.str("initiatorHello").hexToBytes(), c.str("responderHello").hexToBytes(),
            iEph.publicKey, rEph.publicKey, initiator.publicKey, responder.publicKey,
            c.str("initiatorChallenge").hexToBytes(), c.str("responderChallenge").hexToBytes(),
        )
        assertEquals(c.str("transcriptHash"), transcript.hash().toHex())
        assertEquals(c.str("okm"), PairingCrypto.hkdf(iEph.sharedSecret(rEph.publicKey), transcript.hash(), "sb-pair-v1-keys".toByteArray(), 96).toHex())
        val keys = PairingCrypto.derive(iEph, rEph.publicKey, transcript)
        assertEquals(c.str("sas"), keys.shortAuthenticationString)
        assertEquals(c.str("sasDisplay"), PairingCrypto.formatForDisplay(keys.shortAuthenticationString))
        assertEquals(c.str("sasKey"), c.str("okm").take(64))
        assertEquals(c.str("psk"), keys.preSharedKey.toHex())
        assertEquals(c.str("pskFingerprint"), pskFingerprint(keys.preSharedKey))
        assertEquals(c.str("confirmKey"), keys.confirmKey.toHex())
        assertEquals(c.str("confirmInitiator"), PairingCrypto.confirmation(keys.confirmKey, PairingRole.INITIATOR, responder.peerID).toHex())
        assertEquals(c.str("confirmResponder"), PairingCrypto.confirmation(keys.confirmKey, PairingRole.RESPONDER, initiator.peerID).toHex())

        for (side in listOf("initiatorTranscriptSignature", "responderTranscriptSignature")) {
            val sig = c.obj(side)
            assertEquals(c.str("transcriptHash"), sig.str("message"))
            assertTrue(DeviceIdentity.verify(sig.str("signature").hexToBytes(), sig.str("message").hexToBytes(), sig.str("publicKey").hexToBytes()))
        }
        // Kotlin signatures verify too (Ed25519 is deterministic in BC, randomized in CryptoKit).
        assertTrue(DeviceIdentity.verify(initiator.sign(keys.transcriptHash), keys.transcriptHash, initiator.publicKey))

        for ((_, value) in c.obj("messages")) {
            val bytes = value.jsonPrimitive.content.hexToBytes()
            assertEquals(value.jsonPrimitive.content, ControlMessageCoder.encode(ControlMessageCoder.decode(bytes)).toHex())
        }
        val confirm = (ControlMessageCoder.decode(c.obj("messages").str("pairConfirmInitiator").hexToBytes()) as ControlMessage.PairConfirmMsg).confirm
        assertTrue(PairingCrypto.verifyConfirmation(confirm.challengeResponse, keys.confirmKey, PairingRole.INITIATOR, responder.peerID))
        assertTrue(DeviceIdentity.verify(confirm.transcriptSignature, keys.transcriptHash, initiator.publicKey))
        val response = (ControlMessageCoder.decode(c.obj("messages").str("pairResponse").hexToBytes()) as ControlMessage.PairResponseMsg).response
        assertTrue(DeviceIdentity.verify(response.transcriptSignature, keys.transcriptHash, responder.publicKey))
        assertEquals(responder.peerID, PeerIDs.fromSigningKey(response.signingPublicKey))
    }

    @TestFactory
    fun `session-auth`() = Vectors.tests("session-auth") { c ->
        val role = if (c.str("role") == "initiator") PairingRole.INITIATOR else PairingRole.RESPONDER
        val context = SessionContext.signedContext(
            c.str("initiatorNonce").hexToBytes(), c.str("responderNonce").hexToBytes(),
            c.str("initiatorPeerID"), c.str("responderPeerID"), role,
        )
        assertEquals(c.str("signedContext"), context.toHex())
        val sig = c.obj("signature")
        assertEquals(c.str("signedContext"), sig.str("message"))
        assertEquals(c.str("signerPublicKey"), sig.str("publicKey"))
        assertTrue(DeviceIdentity.verify(sig.str("signature").hexToBytes(), context, sig.str("publicKey").hexToBytes()))
        val auth = ControlMessageCoder.decode(c.str("sessionAuthJson").toByteArray()) as ControlMessage.SessionAuth
        assertEquals(sig.str("signature"), auth.signature.toHex())
        assertEquals(c.str("sessionAuthJson"), String(ControlMessageCoder.encode(auth)))
    }

    @TestFactory
    fun ed25519() = Vectors.tests("ed25519") { c ->
        val valid = c.bool("valid")
        val result = DeviceIdentity.verify(c.str("signature").hexToBytes(), c.str("message").hexToBytes(), c.str("publicKey").hexToBytes())
        assertEquals(valid, result)
        if (c.bool("deterministic")) {
            val identity = DeviceIdentity(c.str("privateKeySeed").hexToBytes())
            assertEquals(c.str("publicKey"), identity.publicKey.toHex())
            assertEquals(c.str("signature"), identity.sign(c.str("message").hexToBytes()).toHex())
        }
    }
}
