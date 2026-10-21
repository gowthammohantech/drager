import Foundation
import Testing
@testable import BridgeCore
@testable import BridgeModels
@testable import BridgeSecurity
import BridgeTestSupport

@Suite("Pairing protocol over an in-memory transport")
struct PairingProtocolTests {
    private func channels(faultsA: FakeFrameTransport.Faults = .init()) -> (SessionChannel, SessionChannel, FakeFrameTransport, FakeFrameTransport) {
        let (a, b) = FakeFrameTransport.pair(faultsA: faultsA)
        return (SessionChannel(transport: a, configuration: .handshake), SessionChannel(transport: b, configuration: .handshake), a, b)
    }

    private func run(
        initiatorDecision: ScriptedDecision,
        responderDecision: ScriptedDecision,
        faultsA: FakeFrameTransport.Faults = .init(),
        limiter: PairingRateLimiter = PairingRateLimiter()
    ) async -> (initiator: Result<PairingOutcome, BridgeError>, responder: Result<PairingOutcome, BridgeError>, phone: TestPeer, mac: TestPeer) {
        let phone = TestPeer.iPhone()
        let mac = TestPeer.mac()
        let (ci, cr, a, b) = channels(faultsA: faultsA)
        async let i = capture {
            try await PairingProtocol.runInitiator(channel: ci, identity: phone.identity, device: phone.device, decide: initiatorDecision.handler)
        }
        async let r = capture {
            try await PairingProtocol.runResponder(channel: cr, identity: mac.identity, device: mac.device, rateLimiter: limiter, decide: responderDecision.handler)
        }
        let results = await (i, r)
        withExtendedLifetime((a, b)) {}
        return (results.0, results.1, phone, mac)
    }

    private func capture(_ body: () async throws -> PairingOutcome) async -> Result<PairingOutcome, BridgeError> {
        do { return .success(try await body()) } catch { return .failure(BridgeError.wrap(error, networkContext: true)) }
    }

    @Test("T-01: both users approve matching codes → both sides trust each other with the same PSK")
    func successfulPairing() async throws {
        let iDecision = ScriptedDecision(approve: true)
        let rDecision = ScriptedDecision(approve: true, delay: .milliseconds(50))
        let result = await run(initiatorDecision: iDecision, responderDecision: rDecision)
        let i = try result.initiator.get()
        let r = try result.responder.get()
        #expect(i.preSharedKey == r.preSharedKey)
        #expect(i.preSharedKey.count == 32)
        #expect(i.trustedPeer.peerID == result.mac.identity.peerID)
        #expect(r.trustedPeer.peerID == result.phone.identity.peerID)
        #expect(i.trustedPeer.signingPublicKey == result.mac.identity.publicKeyData)
        #expect(iDecision.recordedPrompts.first?.shortAuthenticationString == rDecision.recordedPrompts.first?.shortAuthenticationString)
        #expect(iDecision.recordedPrompts.first?.peer.displayName == "Test Mac")
    }

    @Test("T-02: responder rejects → no trust on either side")
    func responderRejects() async {
        let result = await run(initiatorDecision: ScriptedDecision(approve: true), responderDecision: ScriptedDecision(approve: false))
        #expect(result.initiator.failureCode == .pairingRejected)
        #expect(result.responder.failureCode == .pairingRejected)
    }

    @Test("Initiator rejects while responder is still deciding → responder aborts without trust")
    func initiatorRejects() async {
        let result = await run(
            initiatorDecision: ScriptedDecision(approve: false),
            responderDecision: ScriptedDecision(approve: true, delay: .milliseconds(200))
        )
        #expect(result.initiator.failureCode == .pairingRejected)
        #expect(result.responder.failureCode == .pairingRejected)
    }

    @Test("A tampered ephemeral key (MITM) is detected and nobody trusts anyone")
    func tamperedKeyDetected() async {
        let faults = FakeFrameTransport.Faults(interceptor: { frame in
            guard case .control(let data) = frame, case .pairRequest(var request) = try? ControlMessageCoder.decode(data) else { return frame }
            request.ephemeralPublicKey = PairingCrypto.makeEphemeralKey().publicKey.rawRepresentation
            return .control(try! ControlMessageCoder.encode(.pairRequest(request)))
        })
        let result = await run(initiatorDecision: ScriptedDecision(approve: true), responderDecision: ScriptedDecision(approve: true), faultsA: faults)
        #expect(result.initiator.failureCode == .authenticationFailed)
        #expect((try? result.responder.get()) == nil)
    }

    @Test("A spoofed HELLO peer ID that doesn't match the signing key is rejected")
    func spoofedPeerID() async {
        let impostor = TestPeer.iPhone("Impostor")
        let faults = FakeFrameTransport.Faults(interceptor: { frame in
            guard case .control(let data) = frame, case .hello(var hello) = try? ControlMessageCoder.decode(data) else { return frame }
            hello.device = DeviceInfo(peerID: impostor.identity.peerID, displayName: "Impostor", platform: .iOS, model: "x")
            return .control(try! ControlMessageCoder.encode(.hello(hello)))
        })
        let result = await run(initiatorDecision: ScriptedDecision(approve: true), responderDecision: ScriptedDecision(approve: true), faultsA: faults)
        #expect(result.responder.failureCode == .authenticationFailed)
        #expect((try? result.initiator.get()) == nil)
    }

    @Test("Repeated failures lock out further pairing attempts")
    func rateLimited() async {
        let limiter = PairingRateLimiter(maxFailures: 2, lockout: .seconds(60))
        for _ in 0..<2 {
            _ = await run(initiatorDecision: ScriptedDecision(approve: true), responderDecision: ScriptedDecision(approve: false), limiter: limiter)
        }
        let result = await run(initiatorDecision: ScriptedDecision(approve: true), responderDecision: ScriptedDecision(approve: true), limiter: limiter)
        #expect(result.responder.failureCode == .pairingRejected)
        #expect(result.initiator.failureCode == .pairingRejected)
    }

    @Test("Protocol version mismatch fails with E012")
    func versionMismatch() async {
        let faults = FakeFrameTransport.Faults(interceptor: { frame in
            guard case .control(let data) = frame, case .hello(var hello) = try? ControlMessageCoder.decode(data) else { return frame }
            hello.protocolVersion = 99
            return .control(try! ControlMessageCoder.encode(.hello(hello)))
        })
        let result = await run(initiatorDecision: ScriptedDecision(approve: true), responderDecision: ScriptedDecision(approve: true), faultsA: faults)
        #expect(result.responder.failureCode == .protocolMismatch)
    }
}

@Suite("Session authentication")
struct SessionAuthenticatorTests {
    private func run(
        phone: TestPeer, mac: TestPeer, phoneTrustsMacAs: TrustedPeer, macTrust: InMemoryTrustDirectory
    ) async -> (Result<Hello, BridgeError>, Result<TrustedPeer, BridgeError>) {
        let (a, b) = FakeFrameTransport.pair()
        let ci = SessionChannel(transport: a, configuration: .handshake)
        let cr = SessionChannel(transport: b, configuration: .handshake)
        async let i: Result<Hello, BridgeError> = {
            do { return .success(try await SessionAuthenticator.authenticateAsInitiator(channel: ci, identity: phone.identity, device: phone.device, expectedPeer: phoneTrustsMacAs, timeout: .seconds(2))) } catch { await ci.close(); return .failure(BridgeError.wrap(error, networkContext: true)) }
        }()
        async let r: Result<TrustedPeer, BridgeError> = {
            do { return .success(try await SessionAuthenticator.authenticateAsResponder(channel: cr, identity: mac.identity, device: mac.device, trust: macTrust, timeout: .seconds(2)).peer) } catch { await cr.close(); return .failure(BridgeError.wrap(error, networkContext: true)) }
        }()
        let result = await (i, r)
        withExtendedLifetime((a, b)) {}
        return result
    }

    @Test("Trusted peers authenticate mutually")
    func mutual() async throws {
        let phone = TestPeer.iPhone(), mac = TestPeer.mac()
        let (i, r) = await run(phone: phone, mac: mac, phoneTrustsMacAs: mac.asTrusted, macTrust: InMemoryTrustDirectory([phone.asTrusted]))
        #expect(try i.get().device.peerID == mac.identity.peerID)
        #expect(try r.get().peerID == phone.identity.peerID)
    }

    @Test("T-11: an untrusted iPhone is refused")
    func untrusted() async {
        let phone = TestPeer.iPhone(), mac = TestPeer.mac()
        let (i, r) = await run(phone: phone, mac: mac, phoneTrustsMacAs: mac.asTrusted, macTrust: InMemoryTrustDirectory())
        #expect(r.failureCode == .authenticationFailed)
        #expect(i.failureCode == .authenticationFailed)
    }

    @Test("A peer holding someone else's trust record but not their key is refused")
    func wrongKey() async {
        let phone = TestPeer.iPhone(), mac = TestPeer.mac(), other = TestPeer.iPhone("Other")
        var forged = phone.asTrusted
        forged.signingPublicKey = other.identity.publicKeyData
        let (_, r) = await run(phone: phone, mac: mac, phoneTrustsMacAs: mac.asTrusted, macTrust: InMemoryTrustDirectory([forged]))
        #expect(r.failureCode == .authenticationFailed)
    }

    @Test("The iPhone refuses a Mac whose key differs from the paired one")
    func macImpersonation() async {
        let phone = TestPeer.iPhone(), mac = TestPeer.mac(), evil = TestPeer.mac("Evil")
        var forged = mac.asTrusted
        forged.signingPublicKey = evil.identity.publicKeyData
        let (i, _) = await run(phone: phone, mac: mac, phoneTrustsMacAs: forged, macTrust: InMemoryTrustDirectory([phone.asTrusted]))
        #expect(i.failureCode == .authenticationFailed)
    }
}

extension Result where Failure == BridgeError {
    var failureCode: BridgeError.Code? {
        if case .failure(let error) = self { return error.code }
        return nil
    }
}
