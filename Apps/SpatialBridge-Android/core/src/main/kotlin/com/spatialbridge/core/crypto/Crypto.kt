package com.spatialbridge.core.crypto

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.PairingRole
import com.spatialbridge.core.model.PeerIDs
import com.spatialbridge.core.util.SecureRandomBytes
import com.spatialbridge.core.util.constantTimeEquals
import com.spatialbridge.core.util.uint32BE
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.macs.HMac
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.security.MessageDigest

/** The device's long-term Ed25519 identity. [seed] is the 32-byte private key (CryptoKit `rawRepresentation`). */
class DeviceIdentity(seed: ByteArray) {
    private val privateKey = Ed25519PrivateKeyParameters(seed.copyOf(), 0)
    val publicKey: ByteArray = privateKey.generatePublicKey().encoded
    val peerID: String = PeerIDs.fromSigningKey(publicKey)

    /** Only for persisting through a secret store. */
    fun exportSeed(): ByteArray = privateKey.encoded

    fun sign(message: ByteArray): ByteArray = Ed25519Signer().run {
        init(true, privateKey)
        update(message, 0, message.size)
        generateSignature()
    }

    val fingerprint: String get() = PeerIDs.fingerprint(peerID)

    companion object {
        fun generate(): DeviceIdentity = DeviceIdentity(SecureRandomBytes.bytes(32))

        fun verify(signature: ByteArray, message: ByteArray, publicKey: ByteArray): Boolean {
            if (publicKey.size != 32 || signature.size != 64) return false
            return runCatching {
                Ed25519Signer().run {
                    init(false, Ed25519PublicKeyParameters(publicKey, 0))
                    update(message, 0, message.size)
                    verifySignature(signature)
                }
            }.getOrDefault(false)
        }
    }
}

/** One X25519 key pair per pairing attempt. */
class EphemeralKey(privateBytes: ByteArray = SecureRandomBytes.bytes(32)) {
    private val privateKey = X25519PrivateKeyParameters(privateBytes, 0)
    val publicKey: ByteArray = privateKey.generatePublicKey().encoded

    fun sharedSecret(peerPublicKey: ByteArray): ByteArray {
        if (peerPublicKey.size != 32) throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "Invalid ephemeral key")
        val agreement = X25519Agreement()
        agreement.init(privateKey)
        val out = ByteArray(agreement.agreementSize)
        try {
            agreement.calculateAgreement(X25519PublicKeyParameters(peerPublicKey, 0), out, 0)
        } catch (e: IllegalStateException) {
            throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "Invalid ephemeral key")
        }
        return out
    }
}

/** Everything both sides saw before the key schedule. HELLOs are the exact wire payloads (ADR-014). */
class PairingTranscript(
    val initiatorHelloPayload: ByteArray,
    val responderHelloPayload: ByteArray,
    val initiatorEphemeralPublicKey: ByteArray,
    val responderEphemeralPublicKey: ByteArray,
    val initiatorSigningPublicKey: ByteArray,
    val responderSigningPublicKey: ByteArray,
    val initiatorChallenge: ByteArray,
    val responderChallenge: ByteArray,
) {
    fun hash(): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        fun absorb(label: String, data: ByteArray) {
            digest.update(label.toByteArray(Charsets.UTF_8))
            digest.update(uint32BE(data.size.toLong()))
            digest.update(data)
        }
        absorb("sb-pair-v1", ByteArray(0))
        absorb("ihello", initiatorHelloPayload)
        absorb("rhello", responderHelloPayload)
        absorb("ieph", initiatorEphemeralPublicKey)
        absorb("reph", responderEphemeralPublicKey)
        absorb("isig", initiatorSigningPublicKey)
        absorb("rsig", responderSigningPublicKey)
        absorb("ichal", initiatorChallenge)
        absorb("rchal", responderChallenge)
        return digest.digest()
    }
}

class PairingKeys(
    val shortAuthenticationString: String,
    val preSharedKey: ByteArray,
    val confirmKey: ByteArray,
    val transcriptHash: ByteArray,
)

object PairingCrypto {
    const val SAS_DIGITS = 6
    private val INFO = "sb-pair-v1-keys".toByteArray(Charsets.UTF_8)

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val generator = HKDFBytesGenerator(SHA256Digest())
        generator.init(HKDFParameters(ikm, salt, info))
        return ByteArray(length).also { generator.generateBytes(it, 0, length) }
    }

    fun derive(ephemeral: EphemeralKey, peerEphemeralPublicKey: ByteArray, transcript: PairingTranscript): PairingKeys =
        deriveFromShared(ephemeral.sharedSecret(peerEphemeralPublicKey), transcript.hash())

    fun deriveFromShared(shared: ByteArray, transcriptHash: ByteArray): PairingKeys {
        val okm = hkdf(shared, transcriptHash, INFO, 96)
        return PairingKeys(
            shortAuthenticationString = shortAuthenticationString(okm.copyOfRange(0, 32)),
            preSharedKey = okm.copyOfRange(32, 64),
            confirmKey = okm.copyOfRange(64, 96),
            transcriptHash = transcriptHash,
        )
    }

    fun shortAuthenticationString(sasKey: ByteArray): String {
        require(sasKey.size >= 4)
        var value = 0L
        for (i in 0 until 4) value = (value shl 8) or (sasKey[i].toLong() and 0xFF)
        return (value % 1_000_000).toString().padStart(SAS_DIGITS, '0')
    }

    fun confirmation(confirmKey: ByteArray, role: PairingRole, approvedPeerID: String): ByteArray {
        val mac = HMac(SHA256Digest())
        mac.init(KeyParameter(confirmKey))
        val message = "sb-confirm-v1:".toByteArray() + role.wire.toByteArray() + byteArrayOf(0x1F) +
            approvedPeerID.toByteArray(Charsets.UTF_8)
        mac.update(message, 0, message.size)
        return ByteArray(mac.macSize).also { mac.doFinal(it, 0) }
    }

    fun verifyConfirmation(candidate: ByteArray, confirmKey: ByteArray, role: PairingRole, approvedPeerID: String): Boolean =
        constantTimeEquals(candidate, confirmation(confirmKey, role, approvedPeerID))

    /** `123 456`. */
    fun formatForDisplay(sas: String): String = if (sas.length == 6) "${sas.take(3)} ${sas.drop(3)}" else sas
}

object SessionContext {
    private val LABEL = "sb-session-v1".toByteArray(Charsets.UTF_8)

    /** `"sb-session-v1" ‖ for each part: UInt32BE(len) ‖ bytes` (CONFORMANCE.md §3). */
    fun signedContext(initiatorNonce: ByteArray, responderNonce: ByteArray, initiator: String, responder: String, signer: PairingRole): ByteArray {
        var out = LABEL
        for (part in listOf(initiatorNonce, responderNonce, initiator.toByteArray(), responder.toByteArray(), signer.wire.toByteArray())) {
            out += uint32BE(part.size.toLong()) + part
        }
        return out
    }
}
