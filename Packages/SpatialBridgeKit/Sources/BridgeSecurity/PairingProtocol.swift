import CryptoKit
import Foundation
public import BridgeCore
public import BridgeModels
import BridgeDiagnostics

/// What the user is asked to compare on both screens.
public struct PairingPrompt: Sendable, Hashable, Identifiable {
    public var id: String { peer.peerID.rawValue + shortAuthenticationString }
    /// Six decimal digits, identical on both devices only if no one is in the middle.
    public let shortAuthenticationString: String
    public let peer: DeviceInfo
    /// `ab12 cd34 ef56 7890`: the peer's key fingerprint.
    public let peerFingerprint: String

    public var formattedCode: String { PairingCrypto.formatForDisplay(shortAuthenticationString) }
}

/// Result of a successful pairing. The caller persists both halves:
/// `trustedPeer` in the trusted-peer store and `preSharedKey` in the Keychain.
public struct PairingOutcome: Sendable {
    public let trustedPeer: TrustedPeer
    public let preSharedKey: Data
}

/// Asks the local user to compare codes. Must return promptly when the
/// calling task is cancelled (the peer rejected or the connection dropped).
public typealias PairingDecisionHandler = @Sendable (PairingPrompt) async -> Bool

/// The pairing handshake (ADR-010, docs/API/PROTOCOL.md):
///
/// ```
/// initiator                         responder
///   HELLO(pair.v1, nonce) ───────────▶
///   ◀─────────── HELLO(pair.v1, nonce)
///   PAIR_REQUEST(x25519, ed25519, chal) ▶
///   ◀── PAIR_RESPONSE(x25519, ed25519, chal, sig_r(transcript))
///        both show SAS; both users decide
///   PAIR_CONFIRM(hmac, sig_i) ◀────────▶ PAIR_CONFIRM(hmac)
/// ```
/// Trust is returned only when the local user approved **and** the peer's
/// confirmation verified. Any rejection or mismatch aborts without trust.
public enum PairingProtocol {
    public struct Timeouts: Sendable {
        public var handshake: Duration
        public var userDecision: Duration
        public init(handshake: Duration = .seconds(30), userDecision: Duration = .seconds(120)) {
            self.handshake = handshake
            self.userDecision = userDecision
        }
    }

    private static let log = BridgeLogger(.pairing)

    // MARK: Initiator (iPhone)

    /// Runs the initiator side. The pairing connection is closed when this returns.
    public static func runInitiator(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        timeouts: Timeouts = Timeouts(),
        decide: @escaping PairingDecisionHandler
    ) async throws -> PairingOutcome {
        try await closing(channel) {
            try await initiate(channel: channel, identity: identity, device: device, timeouts: timeouts, decide: decide)
        }
    }

    private static func closing(_ channel: SessionChannel, _ body: () async throws -> PairingOutcome) async throws -> PairingOutcome {
        do {
            let outcome = try await body()
            await channel.close()
            return outcome
        } catch {
            await channel.close(reason: BridgeError.wrap(error, networkContext: true))
            throw error
        }
    }

    private static func initiate(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        timeouts: Timeouts,
        decide: @escaping PairingDecisionHandler
    ) async throws -> PairingOutcome {
        let timer = MetricTimer(.pairingDuration)
        DiagnosticsRecorder.shared.record(analytics: AnalyticsEvent(name: .pairingStarted))
        let myHello = Hello(device: device, capabilities: [Hello.pairingCapability], sessionNonce: SecureRandom.bytes(32))
        let myHelloPayload = try ControlMessageCoder.encode(.hello(myHello))
        try await channel.send(.control(myHelloPayload))
        let (theirHello, theirHelloPayload) = try await expectHelloFrame(channel, capability: Hello.pairingCapability, timeout: timeouts.handshake)

        let ephemeral = PairingCrypto.makeEphemeralKey()
        let request = PairRequest(
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            signingPublicKey: identity.publicKeyData,
            displayName: device.displayName,
            challenge: SecureRandom.bytes(32)
        )
        try await channel.send(.pairRequest(request))

        let response: PairResponse
        switch try await channel.receiveControl(timeout: timeouts.handshake) {
        case .pairResponse(let r): response = r
        case .pairReject(let reject): throw BridgeError(reject.reason, detail: "responder refused pairing")
        case .error(let error): throw BridgeError(error.code, detail: "responder error")
        default: throw BridgeError(.protocolMismatch, detail: "expected PAIR_RESPONSE")
        }

        guard PeerID(signingPublicKey: response.signingPublicKey) == theirHello.device.peerID else {
            throw BridgeError(.authenticationFailed, detail: "responder key does not match HELLO peer ID")
        }
        let transcript = PairingTranscript(
            initiatorHello: myHello,
            initiatorHelloPayload: myHelloPayload,
            responderHello: theirHello,
            responderHelloPayload: theirHelloPayload,
            initiatorEphemeralPublicKey: request.ephemeralPublicKey,
            responderEphemeralPublicKey: response.ephemeralPublicKey,
            initiatorSigningPublicKey: identity.publicKeyData,
            responderSigningPublicKey: response.signingPublicKey,
            initiatorChallenge: request.challenge,
            responderChallenge: response.challenge
        )
        let keys = try PairingCrypto.derive(
            ephemeralPrivateKey: ephemeral,
            peerEphemeralPublicKey: response.ephemeralPublicKey,
            transcript: transcript
        )
        guard DeviceIdentity.verify(signature: response.transcriptSignature, over: keys.transcriptHash, publicKey: response.signingPublicKey) else {
            try? await channel.send(.pairReject(PairReject(reason: .authenticationFailed)))
            throw BridgeError(.authenticationFailed, detail: "bad responder transcript signature")
        }

        try await converge(
            role: .initiator,
            channel: channel,
            keys: keys,
            identity: identity,
            peer: theirHello.device,
            peerSigningKey: response.signingPublicKey,
            timeouts: timeouts,
            decide: decide
        )
        timer.finish()
        DiagnosticsRecorder.shared.record(analytics: AnalyticsEvent(name: .pairingSucceeded))
        log.notice("Paired with \(theirHello.device.peerID.shortDescription) as initiator")
        return PairingOutcome(trustedPeer: trusted(theirHello.device, key: response.signingPublicKey), preSharedKey: keys.preSharedKey)
    }

    // MARK: Responder (Mac)

    public static func runResponder(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        rateLimiter: PairingRateLimiter,
        timeouts: Timeouts = Timeouts(),
        decide: @escaping PairingDecisionHandler
    ) async throws -> PairingOutcome {
        try await closing(channel) {
            try await acceptPairing(channel: channel, identity: identity, device: device, rateLimiter: rateLimiter, timeouts: timeouts, decide: decide)
        }
    }

    private static func acceptPairing(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        rateLimiter: PairingRateLimiter,
        timeouts: Timeouts,
        decide: @escaping PairingDecisionHandler
    ) async throws -> PairingOutcome {
        let (theirHello, theirHelloPayload) = try await expectHelloFrame(channel, capability: Hello.pairingCapability, timeout: timeouts.handshake)
        let peerID = theirHello.device.peerID
        let peerLocked = await rateLimiter.isLocked(peerID)
        let globallyLocked = await rateLimiter.isLocked(globalLimiterKey)
        if peerLocked || globallyLocked {
            try? await channel.send(.pairReject(PairReject(reason: .pairingRejected)))
            throw BridgeError(.pairingRejected, detail: "rate limited")
        }

        do {
            let outcome = try await respond(
                channel: channel, identity: identity, device: device,
                theirHello: theirHello, theirHelloPayload: theirHelloPayload, timeouts: timeouts, decide: decide
            )
            await rateLimiter.recordSuccess(peerID)
            log.notice("Paired with \(peerID.shortDescription) as responder")
            return outcome
        } catch {
            await rateLimiter.recordFailure(peerID)
            await rateLimiter.recordFailure(globalLimiterKey)
            throw error
        }
    }

    /// Shared bucket so rotating peer IDs cannot bypass the limiter.
    static let globalLimiterKey = PeerID(rawValue: "global")

    private static func respond(
        channel: SessionChannel,
        identity: DeviceIdentity,
        device: DeviceInfo,
        theirHello: Hello,
        theirHelloPayload: Data,
        timeouts: Timeouts,
        decide: @escaping PairingDecisionHandler
    ) async throws -> PairingOutcome {
        let myHello = Hello(device: device, capabilities: [Hello.pairingCapability], sessionNonce: SecureRandom.bytes(32))
        let myHelloPayload = try ControlMessageCoder.encode(.hello(myHello))
        try await channel.send(.control(myHelloPayload))

        guard case .pairRequest(let request) = try await channel.receiveControl(timeout: timeouts.handshake) else {
            throw BridgeError(.protocolMismatch, detail: "expected PAIR_REQUEST")
        }
        guard PeerID(signingPublicKey: request.signingPublicKey) == theirHello.device.peerID else {
            try? await channel.send(.pairReject(PairReject(reason: .authenticationFailed)))
            throw BridgeError(.authenticationFailed, detail: "initiator key does not match HELLO peer ID")
        }

        let ephemeral = PairingCrypto.makeEphemeralKey()
        let challenge = SecureRandom.bytes(32)
        let transcript = PairingTranscript(
            initiatorHello: theirHello,
            initiatorHelloPayload: theirHelloPayload,
            responderHello: myHello,
            responderHelloPayload: myHelloPayload,
            initiatorEphemeralPublicKey: request.ephemeralPublicKey,
            responderEphemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            initiatorSigningPublicKey: request.signingPublicKey,
            responderSigningPublicKey: identity.publicKeyData,
            initiatorChallenge: request.challenge,
            responderChallenge: challenge
        )
        let keys = try PairingCrypto.derive(
            ephemeralPrivateKey: ephemeral,
            peerEphemeralPublicKey: request.ephemeralPublicKey,
            transcript: transcript
        )
        let response = PairResponse(
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            signingPublicKey: identity.publicKeyData,
            displayName: device.displayName,
            challenge: challenge,
            transcriptSignature: try identity.sign(keys.transcriptHash)
        )
        try await channel.send(.pairResponse(response))

        try await converge(
            role: .responder,
            channel: channel,
            keys: keys,
            identity: identity,
            peer: theirHello.device,
            peerSigningKey: request.signingPublicKey,
            timeouts: timeouts,
            decide: decide
        )
        return PairingOutcome(trustedPeer: trusted(theirHello.device, key: request.signingPublicKey), preSharedKey: keys.preSharedKey)
    }

    // MARK: Shared

    private enum ConvergeEvent: Sendable {
        case decision(Bool)
        case message(ControlMessage)
    }

    /// Waits for both the local decision and the peer's confirmation, in either order.
    private static func converge(
        role: PairingRole,
        channel: SessionChannel,
        keys: PairingKeys,
        identity: DeviceIdentity,
        peer: DeviceInfo,
        peerSigningKey: Data,
        timeouts: Timeouts,
        decide: @escaping PairingDecisionHandler
    ) async throws {
        let prompt = PairingPrompt(
            shortAuthenticationString: keys.shortAuthenticationString,
            peer: peer,
            peerFingerprint: fingerprint(of: peer.peerID)
        )
        let peerRole: PairingRole = role == .initiator ? .responder : .initiator

        try await withThrowingTaskGroup(of: ConvergeEvent.self) { group in
            group.addTask { .decision(await decide(prompt)) }
            group.addTask { .message(try await channel.receiveControl(timeout: timeouts.userDecision)) }

            var locallyApproved = false
            var peerConfirmed = false
            var confirmSendError: (any Error)?
            while let event = try await group.next() {
                switch event {
                case .decision(let approved):
                    guard approved else {
                        try? await channel.send(.pairReject(PairReject(reason: .pairingRejected)))
                        group.cancelAll()
                        throw BridgeError(.pairingRejected, detail: "rejected on this device")
                    }
                    locallyApproved = true
                    let confirm = PairConfirm(
                        challengeResponse: PairingCrypto.confirmation(keys: keys, role: role, approvedPeer: peer.peerID),
                        approvedPeerID: peer.peerID,
                        transcriptSignature: role == .initiator ? try identity.sign(keys.transcriptHash) : Data()
                    )
                    do {
                        try await channel.send(.pairConfirm(confirm))
                    } catch {
                        // The peer may have rejected and closed first; let its
                        // buffered message (if any) decide the outcome.
                        confirmSendError = error
                    }
                case .message(.pairReject(let reject)):
                    group.cancelAll()
                    throw BridgeError(reject.reason == .authenticationFailed ? .authenticationFailed : .pairingRejected, detail: "rejected by peer")
                case .message(.pairConfirm(let confirm)):
                    let validMAC = PairingCrypto.verifyConfirmation(
                        confirm.challengeResponse, keys: keys, role: peerRole, approvedPeer: identity.peerID
                    )
                    let validSignature = peerRole == .responder
                        || DeviceIdentity.verify(signature: confirm.transcriptSignature, over: keys.transcriptHash, publicKey: peerSigningKey)
                    guard confirm.approvedPeerID == identity.peerID, validMAC, validSignature else {
                        try? await channel.send(.pairReject(PairReject(reason: .authenticationFailed)))
                        group.cancelAll()
                        throw BridgeError(.authenticationFailed, detail: "peer confirmation did not verify")
                    }
                    peerConfirmed = true
                case .message(.error(let error)):
                    group.cancelAll()
                    throw BridgeError(error.code, detail: "peer error during pairing")
                case .message:
                    group.cancelAll()
                    throw BridgeError(.protocolMismatch, detail: "unexpected message during pairing")
                }
                if locallyApproved && peerConfirmed {
                    group.cancelAll()
                    if let confirmSendError { throw confirmSendError }
                    return
                }
            }
            throw BridgeError(.peerLost, detail: "pairing ended early")
        }
    }

    static func expectHello(_ channel: SessionChannel, capability: String, timeout: Duration) async throws -> Hello {
        try await expectHelloFrame(channel, capability: capability, timeout: timeout).hello
    }

    /// Validated HELLO plus the exact payload bytes it arrived in (ADR-014).
    static func expectHelloFrame(_ channel: SessionChannel, capability: String, timeout: Duration) async throws -> (hello: Hello, payload: Data) {
        let received = try await channel.receiveControlFrame(timeout: timeout)
        let message = received.message
        if case .pairReject(let reject) = message {
            throw BridgeError(reject.reason, detail: "peer refused before HELLO")
        }
        if case .error(let error) = message {
            throw BridgeError(error.code, detail: "peer error before HELLO")
        }
        guard case .hello(let hello) = message else {
            throw BridgeError(.protocolMismatch, detail: "expected HELLO, got \(message.kind.rawValue)")
        }
        guard hello.protocolVersion == BridgeProtocol.version else {
            try? await channel.send(.error(TransferErrorMessage(transferID: nil, code: .protocolMismatch)))
            throw BridgeError(.protocolMismatch, detail: "peer protocol v\(hello.protocolVersion)")
        }
        guard hello.capabilities.contains(capability), hello.sessionNonce.count == 32 else {
            throw BridgeError(.protocolMismatch, detail: "HELLO missing \(capability)")
        }
        guard PeerID(validating: hello.device.peerID.rawValue) != nil else {
            throw BridgeError(.protocolMismatch, detail: "malformed peer ID")
        }
        return (hello, received.payload)
    }

    private static func trusted(_ device: DeviceInfo, key: Data) -> TrustedPeer {
        TrustedPeer(
            peerID: device.peerID,
            displayName: device.displayName,
            platform: device.platform,
            model: device.model,
            signingPublicKey: key
        )
    }

    public static func fingerprint(of peer: PeerID) -> String {
        let raw = Array(peer.rawValue.prefix(16))
        return stride(from: 0, to: raw.count, by: 4).map { String(raw[$0..<min($0 + 4, raw.count)]) }.joined(separator: " ")
    }
}
