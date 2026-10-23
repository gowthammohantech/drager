package com.spatialbridge.core.session

import com.spatialbridge.core.BridgeErrorCode
import com.spatialbridge.core.crypto.DeviceIdentity
import com.spatialbridge.core.crypto.SessionContext
import com.spatialbridge.core.model.BridgeException
import com.spatialbridge.core.model.ControlMessage
import com.spatialbridge.core.model.DeviceInfo
import com.spatialbridge.core.model.Hello
import com.spatialbridge.core.model.PairingRole
import com.spatialbridge.core.model.TrustedPeer
import com.spatialbridge.core.util.SecureRandomBytes

/**
 * Mutual authentication on a TLS-PSK session: each side signs both HELLO nonces, both peer IDs and
 * its role with its long-term Ed25519 key; the other side verifies against the key stored at pairing.
 */
object SessionAuthenticator {
    const val TIMEOUT_MILLIS = 15_000L

    private fun sessionHello(device: DeviceInfo) =
        Hello(device = device, capabilities = Hello.DEFAULT_CAPABILITIES + Hello.SESSION_CAPABILITY, sessionNonce = SecureRandomBytes.bytes(32))

    /** Sender side. [expectedPeer] is the receiver the user chose. */
    suspend fun authenticateAsInitiator(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        expectedPeer: TrustedPeer,
        timeoutMillis: Long = TIMEOUT_MILLIS,
    ): Hello {
        val hello = sessionHello(device)
        channel.send(ControlMessage.HelloMsg(hello))
        val theirHello = PairingProtocol.expectHello(channel, Hello.SESSION_CAPABILITY, timeoutMillis)
        if (theirHello.device.peerID != expectedPeer.peerID) {
            throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "connected to an unexpected peer")
        }
        val mine = SessionContext.signedContext(hello.sessionNonce, theirHello.sessionNonce, identity.peerID, expectedPeer.peerID, PairingRole.INITIATOR)
        channel.send(ControlMessage.SessionAuth(identity.sign(mine)))

        val auth = when (val reply = channel.receiveControl(timeoutMillis)) {
            is ControlMessage.SessionAuth -> reply
            is ControlMessage.Error -> throw BridgeException(reply.code, "responder refused session")
            else -> throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "expected SESSION_AUTH")
        }
        val theirs = SessionContext.signedContext(hello.sessionNonce, theirHello.sessionNonce, identity.peerID, expectedPeer.peerID, PairingRole.RESPONDER)
        if (!DeviceIdentity.verify(auth.signature, theirs, expectedPeer.signingPublicKey)) {
            throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "responder session signature invalid")
        }
        return theirHello
    }

    /** Receiver side. Returns the authenticated trusted peer. */
    suspend fun authenticateAsResponder(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        trust: suspend (String) -> TrustedPeer?,
        timeoutMillis: Long = TIMEOUT_MILLIS,
    ): Pair<TrustedPeer, Hello> {
        val theirHello = PairingProtocol.expectHello(channel, Hello.SESSION_CAPABILITY, timeoutMillis)
        val peer = trust(theirHello.device.peerID) ?: run {
            runCatching { channel.send(ControlMessage.Error(null, BridgeErrorCode.AUTHENTICATION_FAILED)) }
            throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "untrusted peer")
        }
        val myHello = sessionHello(device)
        channel.send(ControlMessage.HelloMsg(myHello))

        val auth = channel.receiveControl(timeoutMillis) as? ControlMessage.SessionAuth
            ?: throw BridgeException(BridgeErrorCode.PROTOCOL_MISMATCH, "expected SESSION_AUTH")
        val theirs = SessionContext.signedContext(theirHello.sessionNonce, myHello.sessionNonce, peer.peerID, identity.peerID, PairingRole.INITIATOR)
        if (!DeviceIdentity.verify(auth.signature, theirs, peer.signingPublicKey)) {
            runCatching { channel.send(ControlMessage.Error(null, BridgeErrorCode.AUTHENTICATION_FAILED)) }
            throw BridgeException(BridgeErrorCode.AUTHENTICATION_FAILED, "initiator session signature invalid")
        }
        val mine = SessionContext.signedContext(theirHello.sessionNonce, myHello.sessionNonce, peer.peerID, identity.peerID, PairingRole.RESPONDER)
        channel.send(ControlMessage.SessionAuth(identity.sign(mine)))
        return peer to theirHello
    }
}
