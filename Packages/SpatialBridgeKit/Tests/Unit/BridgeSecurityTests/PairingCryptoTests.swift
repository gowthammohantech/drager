import CryptoKit
import Foundation
import Testing
@testable import BridgeModels
@testable import BridgeSecurity

@Suite("Pairing cryptography")
struct PairingCryptoTests {
    private func makeParties() throws -> (
        initiator: DeviceIdentity, responder: DeviceIdentity,
        iEph: Curve25519.KeyAgreement.PrivateKey, rEph: Curve25519.KeyAgreement.PrivateKey,
        transcript: PairingTranscript
    ) {
        let initiator = try IdentityStore(secrets: InMemorySecretStore()).loadOrCreate()
        let responder = try IdentityStore(secrets: InMemorySecretStore()).loadOrCreate()
        let iEph = PairingCrypto.makeEphemeralKey()
        let rEph = PairingCrypto.makeEphemeralKey()
        let iHello = Hello(device: DeviceInfo(peerID: initiator.peerID, displayName: "iPhone", platform: .iOS, model: "x"), sessionNonce: Data(repeating: 1, count: 32))
        let rHello = Hello(device: DeviceInfo(peerID: responder.peerID, displayName: "Mac", platform: .macOS, model: "y"), sessionNonce: Data(repeating: 2, count: 32))
        let transcript = PairingTranscript(
            initiatorHello: iHello,
            responderHello: rHello,
            initiatorEphemeralPublicKey: iEph.publicKey.rawRepresentation,
            responderEphemeralPublicKey: rEph.publicKey.rawRepresentation,
            initiatorSigningPublicKey: initiator.publicKeyData,
            responderSigningPublicKey: responder.publicKeyData,
            initiatorChallenge: Data(repeating: 3, count: 32),
            responderChallenge: Data(repeating: 4, count: 32)
        )
        return (initiator, responder, iEph, rEph, transcript)
    }

    @Test("Both sides derive identical SAS, PSK and confirm keys")
    func symmetricDerivation() throws {
        let p = try makeParties()
        let a = try PairingCrypto.derive(ephemeralPrivateKey: p.iEph, peerEphemeralPublicKey: p.rEph.publicKey.rawRepresentation, transcript: p.transcript)
        let b = try PairingCrypto.derive(ephemeralPrivateKey: p.rEph, peerEphemeralPublicKey: p.iEph.publicKey.rawRepresentation, transcript: p.transcript)
        #expect(a == b)
        #expect(a.shortAuthenticationString.count == 6)
        #expect(a.shortAuthenticationString.allSatisfy { $0.isNumber })
        #expect(a.preSharedKey.count == 32)
        #expect(a.confirmKey.count == 32)
        #expect(a.preSharedKey != a.confirmKey)
    }

    @Test("A tampered transcript changes the SAS (MITM detection)")
    func tamperedTranscript() throws {
        let p = try makeParties()
        var tampered = p.transcript
        tampered.responderEphemeralPublicKey = PairingCrypto.makeEphemeralKey().publicKey.rawRepresentation
        let honest = try PairingCrypto.derive(ephemeralPrivateKey: p.iEph, peerEphemeralPublicKey: p.rEph.publicKey.rawRepresentation, transcript: p.transcript)
        let attacked = try PairingCrypto.derive(ephemeralPrivateKey: p.iEph, peerEphemeralPublicKey: p.rEph.publicKey.rawRepresentation, transcript: tampered)
        #expect(honest.transcriptHash != attacked.transcriptHash)
        #expect(honest.preSharedKey != attacked.preSharedKey)
    }

    @Test("Confirmation HMAC verifies only with matching role and peer")
    func confirmation() throws {
        let p = try makeParties()
        let keys = try PairingCrypto.derive(ephemeralPrivateKey: p.iEph, peerEphemeralPublicKey: p.rEph.publicKey.rawRepresentation, transcript: p.transcript)
        let mac = PairingCrypto.confirmation(keys: keys, role: .initiator, approvedPeer: p.responder.peerID)
        #expect(PairingCrypto.verifyConfirmation(mac, keys: keys, role: .initiator, approvedPeer: p.responder.peerID))
        #expect(!PairingCrypto.verifyConfirmation(mac, keys: keys, role: .responder, approvedPeer: p.responder.peerID))
        #expect(!PairingCrypto.verifyConfirmation(mac, keys: keys, role: .initiator, approvedPeer: p.initiator.peerID))
        #expect(!PairingCrypto.verifyConfirmation(Data(repeating: 0, count: 32), keys: keys, role: .initiator, approvedPeer: p.responder.peerID))
    }

    @Test("Transcript signatures verify against the signer's public key only")
    func signatures() throws {
        let p = try makeParties()
        let hash = try p.transcript.hash()
        let signature = try p.responder.sign(hash)
        #expect(DeviceIdentity.verify(signature: signature, over: hash, publicKey: p.responder.publicKeyData))
        #expect(!DeviceIdentity.verify(signature: signature, over: hash, publicKey: p.initiator.publicKeyData))
        #expect(!DeviceIdentity.verify(signature: signature, over: hash + [0], publicKey: p.responder.publicKeyData))
    }

    @Test("SAS extraction is a zero-padded 6-digit number")
    func sasFormatting() {
        #expect(PairingCrypto.shortAuthenticationString(from: Data([0, 0, 0, 7] + [UInt8](repeating: 0, count: 28))) == "000007")
        #expect(PairingCrypto.shortAuthenticationString(from: Data([0xFF, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 28))) == String(format: "%06d", UInt32.max % 1_000_000))
        #expect(PairingCrypto.formatForDisplay("123456") == "123 456")
    }
}

@Suite("Identity and secret stores")
struct IdentityTests {
    @Test("Identity is stable across loads and the peer ID derives from the public key")
    func persistence() throws {
        let secrets = InMemorySecretStore()
        let store = IdentityStore(secrets: secrets)
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        #expect(first.peerID == second.peerID)
        #expect(first.publicKeyData == second.publicKeyData)
        #expect(PeerID(signingPublicKey: first.publicKeyData) == first.peerID)
        #expect(first.peerID.rawValue.count == 32)
        #expect(first.fingerprint.split(separator: " ").count == 4)
    }

    @Test("Pair secret store lists, stores and removes PSKs")
    func pairSecrets() throws {
        let secrets = InMemorySecretStore()
        let pairs = PairSecretStore(secrets: secrets)
        let peer = PeerID(rawValue: String(repeating: "c", count: 32))
        #expect(try pairs.psk(for: peer) == nil)
        try pairs.store(psk: Data(repeating: 9, count: 32), for: peer)
        #expect(try pairs.psk(for: peer)?.count == 32)
        #expect(try pairs.pairedPeers() == [peer])
        try pairs.remove(peer: peer)
        #expect(try pairs.pairedPeers().isEmpty)
    }

    @Test("Reset removes identity and pair secrets")
    func reset() throws {
        let secrets = InMemorySecretStore()
        let store = IdentityStore(secrets: secrets)
        let identity = try store.loadOrCreate()
        try PairSecretStore(secrets: secrets).store(psk: Data(repeating: 1, count: 32), for: PeerID(rawValue: String(repeating: "d", count: 32)))
        try store.resetAll()
        #expect(try secrets.keys(withPrefix: "").isEmpty)
        #expect(try store.loadOrCreate().peerID != identity.peerID)
    }

    @Test("Rate limiter locks after repeated failures and unlocks after the window")
    func rateLimiter() async {
        let clock = ManualClockStub()
        let limiter = PairingRateLimiter(maxFailures: 3, lockout: .seconds(60), clock: clock)
        let peer = PeerID(rawValue: String(repeating: "e", count: 32))
        await limiter.recordFailure(peer)
        await limiter.recordFailure(peer)
        #expect(await !limiter.isLocked(peer))
        await limiter.recordFailure(peer)
        #expect(await limiter.isLocked(peer))
        clock.advance(61)
        #expect(await !limiter.isLocked(peer))
    }
}

/// Tiny clock stub local to this suite (avoids a dependency cycle on BridgeTestSupport for a trivial case).
private final class ManualClockStub: BridgeCore.BridgeClock, @unchecked Sendable {
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { date }
    func sleep(for duration: Duration) async throws {}
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

import BridgeCore
