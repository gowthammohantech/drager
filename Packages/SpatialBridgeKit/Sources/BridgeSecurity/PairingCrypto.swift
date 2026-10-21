import CryptoKit
import Foundation
public import BridgeCore
public import BridgeModels

/// Which side of the pairing handshake a device plays.
public enum PairingRole: String, Sendable, Codable, Hashable {
    /// Opens the connection (iPhone in the MVP).
    case initiator
    /// Accepts the connection (Mac in the MVP).
    case responder
}

/// Everything both sides have seen before the key schedule runs. Hashing this
/// binds the SAS, the PSK and the signatures to the exact exchange.
public struct PairingTranscript: Sendable, Hashable {
    public var initiatorHello: Hello
    public var responderHello: Hello
    public var initiatorEphemeralPublicKey: Data
    public var responderEphemeralPublicKey: Data
    public var initiatorSigningPublicKey: Data
    public var responderSigningPublicKey: Data
    public var initiatorChallenge: Data
    public var responderChallenge: Data

    public init(
        initiatorHello: Hello,
        responderHello: Hello,
        initiatorEphemeralPublicKey: Data,
        responderEphemeralPublicKey: Data,
        initiatorSigningPublicKey: Data,
        responderSigningPublicKey: Data,
        initiatorChallenge: Data,
        responderChallenge: Data
    ) {
        self.initiatorHello = initiatorHello
        self.responderHello = responderHello
        self.initiatorEphemeralPublicKey = initiatorEphemeralPublicKey
        self.responderEphemeralPublicKey = responderEphemeralPublicKey
        self.initiatorSigningPublicKey = initiatorSigningPublicKey
        self.responderSigningPublicKey = responderSigningPublicKey
        self.initiatorChallenge = initiatorChallenge
        self.responderChallenge = responderChallenge
    }

    /// SHA-256 over a canonical, length-prefixed, labelled encoding.
    public func hash() throws -> Data {
        var hasher = SHA256()
        func absorb(_ label: String, _ data: Data) {
            var length = UInt32(data.count).bigEndian
            hasher.update(data: Data(label.utf8))
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: &length, count: 4))
            hasher.update(data: data)
        }
        absorb("sb-pair-v1", Data())
        absorb("ihello", try ControlMessageCoder.encode(.hello(initiatorHello)))
        absorb("rhello", try ControlMessageCoder.encode(.hello(responderHello)))
        absorb("ieph", initiatorEphemeralPublicKey)
        absorb("reph", responderEphemeralPublicKey)
        absorb("isig", initiatorSigningPublicKey)
        absorb("rsig", responderSigningPublicKey)
        absorb("ichal", initiatorChallenge)
        absorb("rchal", responderChallenge)
        return Data(hasher.finalize())
    }
}

/// Keys derived from the pairing key agreement.
public struct PairingKeys: Sendable, Hashable {
    /// Six decimal digits the users compare. Never used as key material.
    public let shortAuthenticationString: String
    /// 32-byte pre-shared key for subsequent TLS sessions.
    public let preSharedKey: Data
    /// 32-byte key for PAIR_CONFIRM HMACs.
    public let confirmKey: Data
    /// Transcript hash the keys were bound to.
    public let transcriptHash: Data
}

public enum PairingCrypto {
    public static let sasDigits = 6

    /// Generates an ephemeral X25519 key for one pairing attempt.
    public static func makeEphemeralKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    /// Runs key agreement and the HKDF schedule. Both sides call this with
    /// the same transcript and obtain identical keys.
    public static func derive(
        ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerEphemeralPublicKey: Data,
        transcript: PairingTranscript
    ) throws -> PairingKeys {
        let peerKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeralPublicKey)
        } catch {
            throw BridgeError(.authenticationFailed, detail: "Invalid ephemeral key")
        }
        let shared = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let transcriptHash = try transcript.hash()
        let okm = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: Data("sb-pair-v1-keys".utf8),
            outputByteCount: 96
        )
        let bytes = okm.withUnsafeBytes { Data($0) }
        let sasKey = bytes.prefix(32)
        let psk = bytes.dropFirst(32).prefix(32)
        let confirm = bytes.dropFirst(64).prefix(32)
        return PairingKeys(
            shortAuthenticationString: shortAuthenticationString(from: Data(sasKey)),
            preSharedKey: Data(psk),
            confirmKey: Data(confirm),
            transcriptHash: transcriptHash
        )
    }

    /// Six zero-padded decimal digits from the first 4 bytes, interpreted big-endian.
    static func shortAuthenticationString(from key: Data) -> String {
        precondition(key.count >= 4)
        let value = key.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let modulus = UInt32(pow(10.0, Double(sasDigits)))
        return String(format: "%0\(sasDigits)d", value % modulus)
    }

    /// HMAC(confirmKey, role || approvedPeerID). Proves the sender has the same keys and names the peer it approved.
    public static func confirmation(keys: PairingKeys, role: PairingRole, approvedPeer: PeerID) -> Data {
        let key = SymmetricKey(data: keys.confirmKey)
        var message = Data("sb-confirm-v1:".utf8)
        message.append(Data(role.rawValue.utf8))
        message.append(0x1F)
        message.append(Data(approvedPeer.rawValue.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    public static func verifyConfirmation(_ candidate: Data, keys: PairingKeys, role: PairingRole, approvedPeer: PeerID) -> Bool {
        let expected = confirmation(keys: keys, role: role, approvedPeer: approvedPeer)
        guard candidate.count == expected.count else { return false }
        // Constant-time comparison.
        var diff: UInt8 = 0
        for (a, b) in zip(candidate, expected) { diff |= a ^ b }
        return diff == 0
    }

    /// Formats a SAS for display: `123 456`.
    public static func formatForDisplay(_ sas: String) -> String {
        guard sas.count == 6 else { return sas }
        let mid = sas.index(sas.startIndex, offsetBy: 3)
        return "\(sas[..<mid]) \(sas[mid...])"
    }
}

/// Tracks pairing attempts to rate-limit SAS guessing.
public actor PairingRateLimiter {
    public let maxFailures: Int
    public let lockout: Duration
    private var failures: [PeerID: (count: Int, lockedUntil: Date?)] = [:]
    private let clock: any BridgeClock

    public init(maxFailures: Int = 3, lockout: Duration = .seconds(60), clock: any BridgeClock = SystemClock()) {
        self.maxFailures = maxFailures
        self.lockout = lockout
        self.clock = clock
    }

    public func isLocked(_ peer: PeerID) -> Bool {
        guard let entry = failures[peer], let until = entry.lockedUntil else { return false }
        if clock.now() >= until {
            failures[peer] = nil
            return false
        }
        return true
    }

    public func recordFailure(_ peer: PeerID) {
        var entry = failures[peer] ?? (0, nil)
        entry.count += 1
        if entry.count >= maxFailures {
            entry.lockedUntil = clock.now().addingTimeInterval(lockout.timeInterval)
            entry.count = 0
        }
        failures[peer] = entry
    }

    public func recordSuccess(_ peer: PeerID) {
        failures[peer] = nil
    }
}
