import Foundation
import BridgeCore
import BridgeModels
import BridgePersistence
import BridgeSecurity

/// Test-only, **unencrypted** JSON secret store (`<state>/secrets.json`).
/// Holds the identity seed and pair PSKs. Never use outside the harness.
final class FileSecretStore: SecretStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return object
    }

    private func save(_ object: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(object).write(to: url, options: .atomic)
    }

    func read(key: String) throws -> Data? {
        lock.withLock { load()[key].flatMap { Data(base64Encoded: $0) } }
    }

    func write(_ value: Data, key: String) throws {
        try lock.withLock {
            var object = load()
            object[key] = value.base64EncodedString()
            try save(object)
        }
    }

    func delete(key: String) throws {
        try lock.withLock {
            var object = load()
            object.removeValue(forKey: key)
            try save(object)
        }
    }

    func keys(withPrefix prefix: String) throws -> [String] {
        lock.withLock { load().keys.filter { $0.hasPrefix(prefix) }.sorted() }
    }
}

/// Everything `--state DIR` holds:
/// - `secrets.json`: identity seed + pair PSKs (base64, unencrypted, test-only)
/// - `trusted-peers.json`: `TrustedPeerStore`
/// - `staging/`: receiver staging area
struct HarnessState: Sendable {
    let directory: URL
    let secrets: FileSecretStore
    let identity: DeviceIdentity
    let trusted: TrustedPeerStore
    let pairSecrets: PairSecretStore

    init(path: String) throws {
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        secrets = FileSecretStore(url: directory.appendingPathComponent("secrets.json"))
        identity = try IdentityStore(secrets: secrets).loadOrCreate()
        trusted = TrustedPeerStore(url: directory.appendingPathComponent(TrustedPeerStore.fileName))
        pairSecrets = PairSecretStore(secrets: secrets)
    }

    func device(platform: DevicePlatform) -> DeviceInfo {
        DeviceInfo(peerID: identity.peerID, displayName: "sb-swift", platform: platform, model: "sb-swift")
    }

    func remember(_ outcome: PairingOutcome) async throws {
        try pairSecrets.store(psk: outcome.preSharedKey, for: outcome.trustedPeer.peerID)
        try await trusted.upsert(outcome.trustedPeer)
    }

    /// Removes `peer`'s pair PSK and trust entry (`unpair`).
    func forget(_ peer: PeerID) async throws {
        try pairSecrets.remove(peer: peer)
        try await trusted.remove(peer)
    }

    func sessionKeys() async -> [(identity: PeerID, preSharedKey: Data)] {
        var keys: [(identity: PeerID, preSharedKey: Data)] = []
        for peer in await trusted.all() {
            if let psk = try? pairSecrets.psk(for: peer.peerID) { keys.append((peer.peerID, psk)) }
        }
        return keys
    }

    /// The peer to send to: `--peer ID` if given, else the most recently paired one.
    func targetPeer(_ requested: String?) async -> TrustedPeer? {
        let all = await trusted.all()
        if let requested { return all.first { $0.peerID.rawValue == requested } }
        return all.max { $0.pairedAt < $1.pairedAt }
    }
}

/// Timeouts. `--test-mode` shortens them so fault scenarios finish quickly.
struct HarnessTimeouts: Sendable {
    let pairing: PairingProtocol.Timeouts
    let limits: TransferLimits

    init(testMode: Bool) {
        if testMode {
            pairing = .init(handshake: .seconds(10), userDecision: .seconds(10))
            limits = TransferLimits(handshakeTimeout: .seconds(10), transferIdleTimeout: .seconds(5))
        } else {
            pairing = .init()
            limits = .default
        }
    }
}
