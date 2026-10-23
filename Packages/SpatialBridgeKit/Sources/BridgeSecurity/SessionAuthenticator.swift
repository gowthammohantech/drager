import Foundation
public import BridgeCore
public import BridgeModels

/// Mutual authentication on a TLS-PSK session.
///
/// TLS-PSK already proves the client holds *some* trusted pair key, but
/// Network.framework does not report which PSK identity was used. This
/// exchange binds the session to a specific trusted peer: each side signs both
/// fresh HELLO nonces, both peer IDs and its role with its long-term Ed25519
/// key, and the other side verifies against the public key stored at pairing.
/// Fresh nonces make captured signatures useless in another session.
public enum SessionAuthenticator {
    public static let label = Data("sb-session-v1".utf8)

    /// The bytes each side signs: the label, then each of both nonces, both
    /// peer IDs and the signer's role as `UInt32BE(len) ‖ bytes`. Public for
    /// the conformance harness (`session-auth` vectors).
    public static func signedContext(initiatorNonce: Data, responderNonce: Data, initiator: PeerID, responder: PeerID, signer: PairingRole) -> Data {
        var data = label
        for part in [initiatorNonce, responderNonce, Data(initiator.rawValue.utf8), Data(responder.rawValue.utf8), Data(signer.rawValue.utf8)] {
            var length = UInt32(part.count).bigEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(part)
        }
        return data
    }

    /// iPhone side. `expectedPeer` is the Mac the user chose.
    public static func authenticateAsInitiator(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        expectedPeer: TrustedPeer,
        timeout: Duration = .seconds(15)
    ) async throws -> Hello {
        let myHello = Hello(device: device, sessionNonce: SecureRandom.bytes(32))
        var hello = myHello
        hello.capabilities.append(Hello.sessionCapability)
        try await channel.send(.hello(hello))
        let theirHello = try await PairingProtocol.expectHello(channel, capability: Hello.sessionCapability, timeout: timeout)
        guard theirHello.device.peerID == expectedPeer.peerID else {
            throw BridgeError(.authenticationFailed, detail: "connected to an unexpected peer")
        }
        let mySignature = try identity.sign(signedContext(
            initiatorNonce: hello.sessionNonce, responderNonce: theirHello.sessionNonce,
            initiator: identity.peerID, responder: expectedPeer.peerID, signer: .initiator
        ))
        try await channel.send(.sessionAuth(SessionAuth(signature: mySignature)))

        let reply = try await channel.receiveControl(timeout: timeout)
        guard case .sessionAuth(let auth) = reply else {
            if case .error(let error) = reply { throw BridgeError(error.code, detail: "responder refused session") }
            throw BridgeError(.protocolMismatch, detail: "expected SESSION_AUTH")
        }
        let context = signedContext(
            initiatorNonce: hello.sessionNonce, responderNonce: theirHello.sessionNonce,
            initiator: identity.peerID, responder: expectedPeer.peerID, signer: .responder
        )
        guard DeviceIdentity.verify(signature: auth.signature, over: context, publicKey: expectedPeer.signingPublicKey) else {
            throw BridgeError(.authenticationFailed, detail: "responder session signature invalid")
        }
        return theirHello
    }

    /// Mac side. Returns the authenticated trusted peer.
    public static func authenticateAsResponder(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        trust: any TrustDirectory,
        timeout: Duration = .seconds(15)
    ) async throws -> (peer: TrustedPeer, hello: Hello) {
        let theirHello = try await PairingProtocol.expectHello(channel, capability: Hello.sessionCapability, timeout: timeout)
        guard let peer = await trust.trustedPeer(theirHello.device.peerID) else {
            try? await channel.send(.error(TransferErrorMessage(transferID: nil, code: .authenticationFailed)))
            throw BridgeError(.authenticationFailed, detail: "untrusted peer \(theirHello.device.peerID.shortDescription)")
        }
        var myHello = Hello(device: device, sessionNonce: SecureRandom.bytes(32))
        myHello.capabilities.append(Hello.sessionCapability)
        try await channel.send(.hello(myHello))

        guard case .sessionAuth(let auth) = try await channel.receiveControl(timeout: timeout) else {
            throw BridgeError(.protocolMismatch, detail: "expected SESSION_AUTH")
        }
        let context = signedContext(
            initiatorNonce: theirHello.sessionNonce, responderNonce: myHello.sessionNonce,
            initiator: peer.peerID, responder: identity.peerID, signer: .initiator
        )
        guard DeviceIdentity.verify(signature: auth.signature, over: context, publicKey: peer.signingPublicKey) else {
            try? await channel.send(.error(TransferErrorMessage(transferID: nil, code: .authenticationFailed)))
            throw BridgeError(.authenticationFailed, detail: "initiator session signature invalid")
        }
        let mySignature = try identity.sign(signedContext(
            initiatorNonce: theirHello.sessionNonce, responderNonce: myHello.sessionNonce,
            initiator: peer.peerID, responder: identity.peerID, signer: .responder
        ))
        try await channel.send(.sessionAuth(SessionAuth(signature: mySignature)))
        return (peer, theirHello)
    }
}
