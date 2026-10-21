import Foundation
import Testing
@testable import BridgeModels
@testable import BridgePersistence

@Suite("Settings store")
@MainActor
struct SettingsStoreTests {
    @Test("Settings persist across store instances")
    func persistence() {
        let kv = InMemoryKeyValueStore()
        let store = SettingsStore(store: kv)
        #expect(store.settings == .default)
        store.settings.gestureSensitivity = 1.5
        store.settings.layout = SpatialLayout(placement: .left, macDisplayIdentifier: "ext", alignmentOffset: 0.1)
        store.settings.hasCompletedOnboarding = true

        let reloaded = SettingsStore(store: kv)
        #expect(reloaded.settings.gestureSensitivity == 1.5)
        #expect(reloaded.settings.layout.placement == .left)
        #expect(reloaded.settings.hasCompletedOnboarding)

        reloaded.reset()
        #expect(SettingsStore(store: kv).settings == .default)
    }

    @Test("Corrupt data falls back to defaults")
    func corrupt() {
        let kv = InMemoryKeyValueStore()
        kv.set(Data("garbage".utf8), forKey: SettingsStore.storageKey)
        #expect(SettingsStore(store: kv).settings == .default)
    }
}

@Suite("File-backed stores")
struct FileStoreTests {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sb-tests-\(UUID().uuidString)").appendingPathComponent(name)
    }

    private let peer = PeerID(rawValue: String(repeating: "7", count: 32))

    @Test("Transfer history records, updates, caps and clears")
    func history() async throws {
        let store = TransferHistoryStore(url: tempURL("history.json"), capacity: 3)
        for i in 0..<5 {
            try await store.record(TransferRecord(id: UUID(), direction: .outgoing, filename: "f\(i).jpeg", contentType: "public.jpeg", byteCount: 10, peerID: peer, peerDisplayName: "Mac", startedAt: Date(timeIntervalSince1970: Double(i))))
        }
        let all = await store.all()
        #expect(all.count == 3)
        #expect(all.first?.filename == "f4.jpeg")

        let id = try #require(all.first?.id)
        try await store.update(id: id) { $0.state = .completed; $0.finishedAt = Date(timeIntervalSince1970: 10) }
        #expect(await store.all().first?.state == .completed)
        #expect(await store.all().first?.duration == 6)

        try await store.clear()
        #expect(await store.all().isEmpty)
    }

    @Test("Trusted peers upsert, mark seen and remove")
    func trustedPeers() async throws {
        let store = TrustedPeerStore(url: tempURL("peers.json"))
        #expect(await !store.isTrusted(peer))
        try await store.upsert(TrustedPeer(peerID: peer, displayName: "Mac", platform: .macOS, model: "Mac16,1", signingPublicKey: Data(repeating: 1, count: 32)))
        #expect(await store.isTrusted(peer))
        try await store.markSeen(peer, serviceName: "Mac._spatialbridge._tcp")
        #expect(await store.peer(peer)?.lastServiceName == "Mac._spatialbridge._tcp")
        try await store.upsert(TrustedPeer(peerID: peer, displayName: "Renamed", platform: .macOS, model: "Mac16,1", signingPublicKey: Data(repeating: 1, count: 32)))
        #expect(await store.all().count == 1)
        #expect(await store.peer(peer)?.displayName == "Renamed")
        try await store.remove(peer)
        #expect(await store.all().isEmpty)
    }

    @Test("JSON store survives reload and delete")
    func jsonStore() async throws {
        let url = tempURL("value.json")
        let store = JSONFileStore<[String]>(url: url)
        try await store.save(["a", "b"])
        #expect(await JSONFileStore<[String]>(url: url).load(default: []) == ["a", "b"])
        try await store.delete()
        #expect(await JSONFileStore<[String]>(url: url).load(default: ["x"]) == ["x"])
    }
}
