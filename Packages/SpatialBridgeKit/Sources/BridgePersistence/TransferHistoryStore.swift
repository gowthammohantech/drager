import Foundation
public import BridgeModels
public import BridgeCore

/// Metadata-only history of transfers (BRD scope: "transfer history (metadata only)").
public actor TransferHistoryStore {
    public static let fileName = "transfer-history.json"

    private let store: JSONFileStore<[TransferRecord]>
    public let capacity: Int

    public init(url: URL, capacity: Int = 200) {
        self.store = JSONFileStore(url: url)
        self.capacity = capacity
    }

    public func all() async -> [TransferRecord] {
        await store.load(default: []).sorted { $0.startedAt > $1.startedAt }
    }

    public func record(_ record: TransferRecord) async throws {
        var records = await store.load(default: [])
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.startedAt > $1.startedAt }
        if records.count > capacity { records.removeLast(records.count - capacity) }
        try await store.save(records)
    }

    public func update(id: UUID, _ mutate: @Sendable (inout TransferRecord) -> Void) async throws {
        var records = await store.load(default: [])
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[index])
        try await store.save(records)
    }

    public func clear() async throws {
        try await store.save([])
    }
}

/// Public metadata of approved peers. Secrets live in `SecretStore`.
public actor TrustedPeerStore {
    public static let fileName = "trusted-peers.json"

    private let store: JSONFileStore<[TrustedPeer]>

    public init(url: URL) {
        self.store = JSONFileStore(url: url)
    }

    public func all() async -> [TrustedPeer] {
        await store.load(default: []).sorted { $0.pairedAt > $1.pairedAt }
    }

    public func peer(_ id: PeerID) async -> TrustedPeer? {
        await store.load(default: []).first { $0.peerID == id }
    }

    public func isTrusted(_ id: PeerID) async -> Bool {
        await peer(id) != nil
    }

    public func upsert(_ peer: TrustedPeer) async throws {
        var peers = await store.load(default: [])
        if let index = peers.firstIndex(where: { $0.peerID == peer.peerID }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
        try await store.save(peers)
    }

    public func markSeen(_ id: PeerID, serviceName: String?, at date: Date = Date()) async throws {
        var peers = await store.load(default: [])
        guard let index = peers.firstIndex(where: { $0.peerID == id }) else { return }
        peers[index].lastSeenAt = date
        if let serviceName { peers[index].lastServiceName = serviceName }
        try await store.save(peers)
    }

    public func remove(_ id: PeerID) async throws {
        var peers = await store.load(default: [])
        peers.removeAll { $0.peerID == id }
        try await store.save(peers)
    }

    public func removeAll() async throws {
        try await store.save([])
    }
}

extension TrustedPeerStore: TrustDirectory {
    public func trustedPeer(_ id: PeerID) async -> TrustedPeer? { await peer(id) }
    public func allTrusted() async -> [TrustedPeer] { await all() }
}
