import Foundation
import Network
import Testing
@testable import BridgeCore
@testable import BridgeModels
@testable import BridgeNetworking
@testable import BridgePersistence
@testable import BridgeSecurity
@testable import BridgeServices
@testable import BridgeTransfer
import BridgeTestSupport
import os

/// Resolves the receiver's loopback listeners as if Bonjour had found them.
final class LoopbackLocator: PeerLocating, @unchecked Sendable {
    private let advertiser: ServiceAdvertiser
    private let peer: DiscoveredPeer
    private let peerBroadcaster: Broadcaster<[DiscoveredPeer]>
    private let stateBroadcaster = Broadcaster<DiscoveryState>(.browsing)

    init(advertiser: ServiceAdvertiser, mac: TestPeer) {
        self.advertiser = advertiser
        self.peer = DiscoveredPeer(
            serviceName: mac.device.displayName, advertisedPeerID: mac.identity.peerID,
            advertisedDisplayName: mac.device.displayName, platform: .macOS, protocolVersion: BridgeProtocol.version,
            roles: [.session, .pairing]
        )
        peerBroadcaster = Broadcaster([peer])
    }

    var peers: AsyncStream<[DiscoveredPeer]> { peerBroadcaster.stream() }
    var state: AsyncStream<DiscoveryState> { stateBroadcaster.stream() }
    var currentPeers: [DiscoveredPeer] { [peer] }
    var discovered: DiscoveredPeer { peer }

    func endpoint(for peerID: String, role: ServiceRole) -> NWEndpoint? {
        guard peerID == peer.id else { return nil }
        let port = role == .session ? advertiser.sessionPort : advertiser.pairingPort
        return port.map { NetworkLoopbackTests.endpoint($0) }
    }

    func start() async {}
    func stop() async {}
    func restart() async { peerBroadcaster.send([peer]) }
    /// Nudges subscribers (as a Bonjour update would after a listener restart).
    func republish() { peerBroadcaster.send([peer]) }
}

/// Persistent stores for one device, reusable across service restarts (T-12).
struct DeviceStores {
    let peer: TestPeer
    let trusted: TrustedPeerStore
    let history: TransferHistoryStore
    var pairSecrets: PairSecretStore { PairSecretStore(secrets: peer.secrets) }

    init(peer: TestPeer, root: URL) {
        self.peer = peer
        let dir = root.appendingPathComponent(peer.identity.peerID.shortDescription, isDirectory: true)
        trusted = TrustedPeerStore(url: dir.appendingPathComponent(TrustedPeerStore.fileName))
        history = TransferHistoryStore(url: dir.appendingPathComponent(TransferHistoryStore.fileName))
    }

    /// Fresh store instances over the same files, as after an app relaunch.
    func reopened(root: URL) -> DeviceStores { DeviceStores(peer: peer, root: root) }
}

@Suite("Services end to end (loopback)", .serialized, .timeLimit(.minutes(3)))
struct ServiceEndToEndTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-e2e-\(UUID().uuidString)", isDirectory: true)

    func makeReceiver(_ stores: DeviceStores, approve: Bool = true) async throws -> (ReceiverService, URL) {
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let service = ReceiverService(dependencies: .init(
            identity: stores.peer.identity, device: stores.peer.device,
            pairSecrets: stores.pairSecrets, trustedPeers: stores.trusted, history: stores.history,
            staging: try StagingArea(directory: root.appendingPathComponent("Staging", isDirectory: true)),
            destination: FolderDestinationStore(folder: destination),
            advertiser: .init(loopbackOnly: true)
        ))
        await service.setPairingDecisionHandler(ScriptedDecision(approve: approve).handler)
        await service.start(available: true, allowPairing: true)
        _ = try await NetworkLoopbackTests.waitForPort { service.advertiser.sessionPort }
        _ = try await NetworkLoopbackTests.waitForPort { service.advertiser.pairingPort }
        return (service, destination)
    }

    func makeSender(_ stores: DeviceStores, locator: LoopbackLocator) -> SenderService {
        SenderService(dependencies: .init(
            identity: stores.peer.identity, device: stores.peer.device,
            pairSecrets: stores.pairSecrets, trustedPeers: stores.trusted, history: stores.history,
            locator: locator,
            retry: RetryPolicy(maxAttempts: .max, initialDelay: .milliseconds(100), maxDelay: .milliseconds(500)),
            watchNetworkPath: false
        ))
    }

    func waitForStatus(_ service: SenderService, timeout: Duration = .seconds(15), _ predicate: @escaping @Sendable (LinkStatus) -> Bool) async throws -> LinkStatus {
        try await withBridgeTimeout(timeout) {
            for await status in service.status.stream() where predicate(status) { return status }
            throw BridgeError(.timeout)
        }
    }

    func file(_ megabytes: Double, name: String) throws -> OutgoingFile {
        let dir = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return OutgoingFile(url: try RandomFileFactory.make(byteCount: Int(megabytes * 1_048_576), in: dir, name: name))
    }

    @Test("Pair → connect → send: the Mac stores the file and both sides record history")
    func fullFlow() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = DeviceStores(peer: .iPhone(), root: root), mac = DeviceStores(peer: .mac(), root: root)
        let (receiver, destination) = try await makeReceiver(mac)
        let locator = LoopbackLocator(advertiser: receiver.advertiser, mac: mac.peer)
        let sender = makeSender(phone, locator: locator)
        await sender.start()
        #expect(try await waitForStatus(sender) { $0.state == .idle }.peer == nil)

        let trusted = try await sender.pair(with: locator.discovered, decide: ScriptedDecision(approve: true).handler)
        #expect(trusted.peerID == mac.peer.identity.peerID)
        #expect(await mac.trusted.isTrusted(phone.peer.identity.peerID))
        locator.republish()
        let connected = try await waitForStatus(sender) { $0.isConnected }
        #expect(connected.peer?.peerID == mac.peer.identity.peerID)
        #expect(try await withBridgeTimeout(.seconds(5)) {
            for await peers in receiver.connectedPeers.stream() where !peers.isEmpty { return peers.first?.peerID }
            return nil
        } == phone.peer.identity.peerID)

        let outgoing = try file(5, name: "Holiday.heic")
        let committed = try await sender.send(outgoing, gesture: ExitGesture(edge: .top, normalizedPosition: 0.3, outwardVelocity: 800)) { _ in }
        #expect(committed.savedFilename == "Holiday.heic")
        #expect(try sha256(destination.appendingPathComponent("Holiday.heic")) == sha256(outgoing.url))

        let sent = await phone.history.all()
        #expect(sent.first?.state == .completed && sent.first?.direction == .outgoing)
        let receivedOK = try await withBridgeTimeout(.seconds(5)) {
            while true {
                if let first = await mac.history.all().first, first.state == .completed { return first }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        #expect(receivedOK.savedPath?.hasSuffix("Holiday.heic") == true)

        await sender.stop()
        await receiver.stop()
    }

    @Test("T-12: after restarting both apps, trust persists and transfers work without re-pairing")
    func restartPersistence() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = DeviceStores(peer: .iPhone(), root: root), mac = DeviceStores(peer: .mac(), root: root)
        do {
            let (receiver, _) = try await makeReceiver(mac)
            let locator = LoopbackLocator(advertiser: receiver.advertiser, mac: mac.peer)
            let sender = makeSender(phone, locator: locator)
            await sender.start()
            _ = try await sender.pair(with: locator.discovered, decide: ScriptedDecision(approve: true).handler)
            await sender.stop()
            await receiver.stop()
        }
        // "Relaunch": new service instances over reopened stores, same Keychain contents.
        let phone2 = phone.reopened(root: root), mac2 = mac.reopened(root: root)
        let (receiver, destination) = try await makeReceiver(mac2)
        let locator = LoopbackLocator(advertiser: receiver.advertiser, mac: mac2.peer)
        let sender = makeSender(phone2, locator: locator)
        await sender.start()
        _ = try await waitForStatus(sender) { $0.isConnected }
        let committed = try await sender.send(try file(1, name: "after-restart.png"), gesture: nil) { _ in }
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(committed.savedFilename).path))
        await sender.stop()
        await receiver.stop()
    }

    @Test("Reconnection: the iPhone reconnects after the Mac toggles availability")
    func reconnects() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = DeviceStores(peer: .iPhone(), root: root), mac = DeviceStores(peer: .mac(), root: root)
        let (receiver, _) = try await makeReceiver(mac)
        let locator = LoopbackLocator(advertiser: receiver.advertiser, mac: mac.peer)
        let sender = makeSender(phone, locator: locator)
        await sender.start()
        _ = try await sender.pair(with: locator.discovered, decide: ScriptedDecision(approve: true).handler)
        _ = try await waitForStatus(sender) { $0.isConnected }

        await receiver.setAvailable(false)
        _ = try await waitForStatus(sender) { !$0.isConnected }
        await #expect(throws: BridgeError.self) { _ = try await sender.send(try file(0.1, name: "offline.txt"), gesture: nil) { _ in } }

        await receiver.setAvailable(true)
        _ = try await NetworkLoopbackTests.waitForPort { receiver.advertiser.sessionPort }
        locator.republish()
        _ = try await waitForStatus(sender) { $0.isConnected }
        _ = try await sender.send(try file(0.5, name: "back-online.txt"), gesture: nil) { _ in }
        await sender.stop()
        await receiver.stop()
    }

    @Test("Unpairing on the Mac revokes the iPhone: it can no longer connect or send")
    func macUnpairRevokes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = DeviceStores(peer: .iPhone(), root: root), mac = DeviceStores(peer: .mac(), root: root)
        let (receiver, _) = try await makeReceiver(mac)
        let locator = LoopbackLocator(advertiser: receiver.advertiser, mac: mac.peer)
        let sender = makeSender(phone, locator: locator)
        await sender.start()
        _ = try await sender.pair(with: locator.discovered, decide: ScriptedDecision(approve: true).handler)
        _ = try await waitForStatus(sender) { $0.isConnected }

        try await receiver.unpair(phone.peer.identity.peerID)
        _ = try await NetworkLoopbackTests.waitForPort { receiver.advertiser.sessionPort }
        locator.republish()
        let status = try await waitForStatus(sender) { $0.state == .disconnected(reason: .authenticationFailed) }
        #expect(status.lastError == .authenticationFailed)
        #expect(await mac.trusted.all().isEmpty)
        await sender.stop()
        await receiver.stop()
    }

    @Test("T-02: when the Mac user rejects pairing, nothing is trusted on either side")
    func rejectedPairing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = DeviceStores(peer: .iPhone(), root: root), mac = DeviceStores(peer: .mac(), root: root)
        let (receiver, _) = try await makeReceiver(mac, approve: false)
        let locator = LoopbackLocator(advertiser: receiver.advertiser, mac: mac.peer)
        let sender = makeSender(phone, locator: locator)
        await sender.start()
        await #expect {
            _ = try await sender.pair(with: locator.discovered, decide: ScriptedDecision(approve: true).handler)
        } throws: { ($0 as? BridgeError)?.code == .pairingRejected }
        #expect(await phone.trusted.all().isEmpty)
        #expect(await mac.trusted.all().isEmpty)
        #expect(try phone.pairSecrets.pairedPeers().isEmpty)
        await #expect(throws: BridgeError.self) { _ = try await sender.send(try file(0.1, name: "x.txt"), gesture: nil) { _ in } }
        await sender.stop()
        await receiver.stop()
    }
}
