import CryptoKit
import Foundation
public import BridgeCore
public import BridgeModels
import BridgeDiagnostics

extension PeerID {
    /// Derives the peer identifier from a raw Ed25519 public key: first 128 bits of SHA-256, lowercase hex.
    public init(signingPublicKey: Data) {
        let digest = SHA256.hash(data: signingPublicKey)
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        self.init(rawValue: hex)
    }
}

/// The device's long-term identity: an Ed25519 signing key whose public half
/// identifies the device to peers. The seed is stored in the secret store.
public struct DeviceIdentity: Sendable {
    public let signingKey: Curve25519.Signing.PrivateKey
    public let peerID: PeerID

    public init(signingKey: Curve25519.Signing.PrivateKey) {
        self.signingKey = signingKey
        self.peerID = PeerID(signingPublicKey: signingKey.publicKey.rawRepresentation)
    }

    public var publicKeyData: Data { signingKey.publicKey.rawRepresentation }

    public func sign(_ data: Data) throws -> Data {
        try signingKey.signature(for: data)
    }

    public static func verify(signature: Data, over data: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// Short fingerprint for display: `ab12 cd34 ef56 7890`.
    public var fingerprint: String {
        let raw = peerID.rawValue.prefix(16)
        return stride(from: 0, to: raw.count, by: 4).map { offset in
            let start = raw.index(raw.startIndex, offsetBy: offset)
            let end = raw.index(start, offsetBy: 4)
            return String(raw[start..<end])
        }.joined(separator: " ")
    }
}

/// Loads or creates the device identity from a `SecretStore`.
public struct IdentityStore: Sendable {
    private let secrets: any SecretStore
    private let log = BridgeLogger(.pairing)

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public func loadOrCreate() throws -> DeviceIdentity {
        if let seed = try secrets.read(key: BridgeProtocol.SecretKey.identitySeed),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) {
            return DeviceIdentity(signingKey: key)
        }
        let key = Curve25519.Signing.PrivateKey()
        try secrets.write(key.rawRepresentation, key: BridgeProtocol.SecretKey.identitySeed)
        let identity = DeviceIdentity(signingKey: key)
        log.notice("Created new device identity \(identity.peerID.shortDescription)")
        return identity
    }

    /// Destroys the identity and all pair secrets. Used by "Reset Drager".
    public func resetAll() throws {
        try secrets.delete(key: BridgeProtocol.SecretKey.identitySeed)
        for key in try secrets.keys(withPrefix: BridgeProtocol.SecretKey.pairPSKPrefix) {
            try secrets.delete(key: key)
        }
    }
}

/// Per-pair pre-shared keys derived at pairing time and used for TLS-PSK sessions.
public struct PairSecretStore: Sendable {
    private let secrets: any SecretStore

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    public func psk(for peer: PeerID) throws -> Data? {
        try secrets.read(key: BridgeProtocol.SecretKey.pairPSK(for: peer))
    }

    public func store(psk: Data, for peer: PeerID) throws {
        precondition(psk.count == 32, "PSK must be 32 bytes")
        try secrets.write(psk, key: BridgeProtocol.SecretKey.pairPSK(for: peer))
    }

    public func remove(peer: PeerID) throws {
        try secrets.delete(key: BridgeProtocol.SecretKey.pairPSK(for: peer))
    }

    /// All peers that have a PSK stored.
    public func pairedPeers() throws -> [PeerID] {
        try secrets.keys(withPrefix: BridgeProtocol.SecretKey.pairPSKPrefix).compactMap { key in
            PeerID(validating: String(key.dropFirst(BridgeProtocol.SecretKey.pairPSKPrefix.count)))
        }
    }
}
