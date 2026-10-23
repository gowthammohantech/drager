import CryptoKit
import Foundation
import Network
import Testing
@testable import BridgeCore
@testable import BridgeModels
@testable import BridgeNetworking
@testable import BridgeSecurity
@testable import BridgeTransfer
import BridgeTestSupport
import os

/// Collects receiver events for assertions.
final class EventLog: Sendable {
    private let events = OSAllocatedUnfairLock<[ReceiverEvent]>(initialState: [])
    func append(_ event: ReceiverEvent) { events.withLock { $0.append($0.isEmpty ? event : event) } }
    var all: [ReceiverEvent] { events.withLock { $0 } }

    var committedURLs: [URL] {
        all.compactMap { if case .committed(_, let url, _) = $0 { return url } else { return nil } }
    }
    var failures: [BridgeError.Code] {
        all.compactMap { if case .failed(_, let reason, _) = $0 { return reason.code } else { return nil } }
    }
    var rejections: [BridgeError.Code] {
        all.compactMap { if case .rejected(_, let reason, _) = $0 { return reason.code } else { return nil } }
    }
    var replays: [(transferID: UUID, savedFilename: String)] {
        all.compactMap { if case .replayed(let offer, let name, _) = $0 { return (offer.transferID, name) } else { return nil } }
    }
    var acceptedCount: Int { all.filter { if case .accepted = $0 { return true } else { return false } }.count }

    func waitFor(_ condition: @escaping @Sendable (EventLog) -> Bool, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(self) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(self)
    }
}

/// Destination that reports a fixed free-space figure.
struct LimitedCapacityStore: DestinationStore {
    let base: FolderDestinationStore
    let capacity: Int64
    func displayPath() async -> String? { await base.displayPath() }
    func validateAccess() async throws { try await base.validateAccess() }
    func availableCapacity() async throws -> Int64 { capacity }
    func commit(stagedFile: URL, suggestedName: String) async throws -> URL { try await base.commit(stagedFile: stagedFile, suggestedName: suggestedName) }
}

/// One sender ↔ receiver pair with a temporary destination and staging area.
struct TransferHarness: @unchecked Sendable {
    let phone: TestPeer
    let mac: TestPeer
    let root: URL
    let destinationFolder: URL
    let staging: StagingArea
    let ledger = TransferOutcomeLedger()
    let events = EventLog()
    let senderChannel: SessionChannel
    let receiverChannel: SessionChannel
    let keepAlive: [AnyObject]

    enum Link {
        case fake(sender: FakeFrameTransport.Faults = .init(), receiver: FakeFrameTransport.Faults = .init())
        case loopbackTLS
    }

    static func make(
        link: Link = .fake(),
        policy: TransferPolicy = .default,
        destination makeDestination: ((URL) -> any DestinationStore)? = nil
    ) async throws -> TransferHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-transfer-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = try StagingArea(directory: root.appendingPathComponent("Staging", isDirectory: true))
        let phone = TestPeer.iPhone(), mac = TestPeer.mac()

        let senderTransport: any FrameTransport
        let receiverTransport: any FrameTransport
        var keepAlive: [AnyObject] = []
        switch link {
        case .fake(let senderFaults, let receiverFaults):
            let (a, b) = FakeFrameTransport.pair(faultsA: senderFaults, faultsB: receiverFaults)
            senderTransport = a
            receiverTransport = b
            keepAlive = [a, b]
        case .loopbackTLS:
            let key = SecureRandom.bytes(32)
            let advertiser = ServiceAdvertiser(device: mac.device, configuration: .init(loopbackOnly: true))
            advertiser.start(sessionKeys: [(phone.identity.peerID, key)], pairingEnabled: false)
            let port = try await NetworkLoopbackTests.waitForPort { advertiser.sessionPort }
            async let incoming: NWFrameTransport? = {
                for await item in advertiser.incoming { if case .session(let t) = item { return t } }
                return nil
            }()
            senderTransport = try await PeerConnector.openSession(to: NetworkLoopbackTests.endpoint(port), identity: phone.identity.peerID, preSharedKey: key)
            guard let accepted = await incoming else { throw BridgeError(.peerLost) }
            receiverTransport = accepted
            keepAlive = [advertiser]
        }

        let harness = TransferHarness(
            phone: phone, mac: mac, root: root, destinationFolder: destination, staging: staging,
            senderChannel: SessionChannel(transport: senderTransport),
            receiverChannel: SessionChannel(transport: receiverTransport),
            keepAlive: keepAlive
        )
        let store = makeDestination?(destination) ?? FolderDestinationStore(folder: destination)
        let receiver = TransferReceiver(
            channel: harness.receiverChannel,
            peer: phone.asTrusted,
            localPeerID: mac.identity.peerID,
            destination: store,
            staging: staging,
            ledger: harness.ledger,
            configuration: .init(policy: policy),
            emit: { [events = harness.events] in events.append($0) }
        )
        Task { await receiver.run() }
        return harness
    }

    init(phone: TestPeer, mac: TestPeer, root: URL, destinationFolder: URL, staging: StagingArea, senderChannel: SessionChannel, receiverChannel: SessionChannel, keepAlive: [AnyObject]) {
        self.phone = phone
        self.mac = mac
        self.root = root
        self.destinationFolder = destinationFolder
        self.staging = staging
        self.senderChannel = senderChannel
        self.receiverChannel = receiverChannel
        self.keepAlive = keepAlive
    }

    var sender: TransferSender {
        TransferSender(channel: senderChannel, localPeerID: phone.identity.peerID, remotePeerID: mac.identity.peerID)
    }

    func makeFile(megabytes: Double, name: String = "photo.jpeg", seed: UInt64 = 7) throws -> OutgoingFile {
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let url = try RandomFileFactory.make(byteCount: Int(megabytes * 1_048_576), seed: seed, in: source, name: name)
        return OutgoingFile(url: url)
    }

    var destinationContents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: destinationFolder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    var stagingContents: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: staging.directory.path)) ?? []
    }

    func cleanUp() async {
        await senderChannel.close()
        await receiverChannel.close()
        for object in keepAlive { (object as? ServiceAdvertiser)?.stop() }
        try? FileManager.default.removeItem(at: root)
    }
}

func sha256(_ url: URL) throws -> String {
    var hasher = SHA256()
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    while try autoreleasepool(invoking: { () throws -> Bool in
        guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { return false }
        hasher.update(data: data)
        return true
    }) {}
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

@Suite("File transfer", .serialized, .timeLimit(.minutes(5)))
struct TransferTests {
    @Test("T-05: 1, 10 and 100 MiB files arrive byte-identical over TLS loopback", arguments: [1.0, 10.0, 100.0])
    func integrity(megabytes: Double) async throws {
        let h = try await TransferHarness.make(link: .loopbackTLS)
        defer { Task { await h.cleanUp() } }
        let file = try h.makeFile(megabytes: megabytes, name: "IMG_\(Int(megabytes)).jpeg")
        let snapshots = OSAllocatedUnfairLock<[TransferProgressSnapshot]>(initialState: [])
        let start = ContinuousClock.now
        let committed = try await h.sender.send(file, gesture: ExitGesture(edge: .top, normalizedPosition: 0.5, outwardVelocity: 900)) { s in
            snapshots.withLock { $0.append(s) }
        }
        let elapsed = (ContinuousClock.now - start).timeInterval
        #expect(committed.savedFilename == "IMG_\(Int(megabytes)).jpeg")
        let saved = h.destinationFolder.appendingPathComponent(committed.savedFilename)
        #expect(try sha256(saved) == sha256(file.url))
        #expect(h.stagingContents.isEmpty)
        let states = snapshots.withLock { $0.map(\.state) }
        #expect(states.last == .completed)
        #expect(!states.contains(.failed))
        // Success never precedes the receiver's commit.
        #expect(await h.events.waitFor { !$0.committedURLs.isEmpty })
        let fractions = snapshots.withLock { $0.map(\.fractionCompleted) }
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 } || states.contains(.verifying))
        print("T-05 \(Int(megabytes)) MiB: \(String(format: "%.2f", elapsed)) s, \(String(format: "%.1f", megabytes / elapsed)) MiB/s")
    }

    @Test("T-06: a dropped link mid-stream leaves no final file and a retryable error")
    func disconnectMidStream() async throws {
        let h = try await TransferHarness.make(link: .fake(sender: .init(failAfterFrames: 12)))
        defer { Task { await h.cleanUp() } }
        let file = try h.makeFile(megabytes: 8)
        await #expect {
            _ = try await h.sender.send(file, gesture: nil) { _ in }
        } throws: { error in
            let bridge = error as? BridgeError
            return bridge?.code == .peerLost && bridge?.isRetryable == true
        }
        #expect(await h.events.waitFor { !$0.failures.isEmpty })
        #expect(h.destinationContents.isEmpty)
        #expect(h.stagingContents.isEmpty)
    }

    @Test("T-07: a corrupted chunk is detected by SHA-256 and discarded")
    func corruptedChunk() async throws {
        let corrupt = FakeFrameTransport.Faults(interceptor: { frame in
            guard case .chunk(var chunk) = frame, chunk.sequence == 3 else { return frame }
            chunk.payload[100] ^= 0x5A
            return .chunk(chunk)
        })
        let h = try await TransferHarness.make(link: .fake(sender: corrupt))
        defer { Task { await h.cleanUp() } }
        let file = try h.makeFile(megabytes: 2)
        await #expect {
            _ = try await h.sender.send(file, gesture: nil) { _ in }
        } throws: { ($0 as? BridgeError)?.code == .hashMismatch }
        #expect(h.destinationContents.isEmpty)
        #expect(h.stagingContents.isEmpty)
    }

    @Test("T-09: duplicate filenames never overwrite")
    func duplicateNames() async throws {
        let h = try await TransferHarness.make()
        defer { Task { await h.cleanUp() } }
        let first = try h.makeFile(megabytes: 0.25, name: "IMG_0001.jpeg", seed: 1)
        let firstHash = try sha256(first.url)
        _ = try await h.sender.send(first, gesture: nil) { _ in }
        let second = try h.makeFile(megabytes: 0.25, name: "IMG_0001.jpeg", seed: 2)
        let committed = try await h.sender.send(second, gesture: nil) { _ in }
        #expect(committed.savedFilename == "IMG_0001 2.jpeg")
        #expect(h.destinationContents == ["IMG_0001 2.jpeg", "IMG_0001.jpeg"])
        #expect(try sha256(h.destinationFolder.appendingPathComponent("IMG_0001.jpeg")) == firstHash)
    }

    @Test("Path traversal and unsafe names in a raw offer are rejected before any bytes")
    func traversalRejected() async throws {
        let h = try await TransferHarness.make()
        defer { Task { await h.cleanUp() } }
        for name in ["../../evil.sh", "/etc/passwd", ".hidden", "a/b.txt", "con\u{0}trol.txt"] {
            let offer = TransferOffer(
                sourcePeerID: h.phone.identity.peerID, targetPeerID: h.mac.identity.peerID,
                filename: name, contentType: "public.data", byteCount: 10,
                sha256Hex: String(repeating: "a", count: 64), gesture: nil
            )
            try await h.senderChannel.send(.transferOffer(offer))
            guard case .transferReject(let reject) = try await h.senderChannel.receiveControl(timeout: .seconds(5)) else {
                Issue.record("expected reject for \(name)"); continue
            }
            #expect(reject.reason == .unsupportedFile, "\(name)")
        }
        #expect(h.destinationContents.isEmpty)
    }

    @Test("Oversized offers are rejected with E007")
    func oversize() async throws {
        let policy = TransferPolicy(limits: TransferLimits(maxFileBytes: 1_048_576))
        let h = try await TransferHarness.make(policy: policy)
        defer { Task { await h.cleanUp() } }
        let file = try h.makeFile(megabytes: 2)
        await #expect {
            _ = try await h.sender.send(file, gesture: nil) { _ in }
        } throws: { ($0 as? BridgeError)?.code == .sizeLimit }
        #expect(await h.events.waitFor { $0.rejections == [.sizeLimit] })
    }

    @Test("Executables are never accepted")
    func deniedType() async throws {
        let h = try await TransferHarness.make()
        defer { Task { await h.cleanUp() } }
        let file = try h.makeFile(megabytes: 0.1, name: "run.sh")
        await #expect {
            _ = try await h.sender.send(OutgoingFile(url: file.url, contentType: "public.shell-script"), gesture: nil) { _ in }
        } throws: { ($0 as? BridgeError)?.code == .unsupportedFile }
    }

    @Test("Insufficient free space is rejected with E008 before streaming")
    func diskFull() async throws {
        let h = try await TransferHarness.make(destination: { LimitedCapacityStore(base: FolderDestinationStore(folder: $0), capacity: 1024) })
        defer { Task { await h.cleanUp() } }
        let file = try h.makeFile(megabytes: 1)
        await #expect {
            _ = try await h.sender.send(file, gesture: nil) { _ in }
        } throws: { ($0 as? BridgeError)?.code == .insufficientStorage }
        #expect(await h.events.waitFor { $0.acceptedCount == 0 && $0.rejections == [.insufficientStorage] })
    }

    @Test("T-08 (package level): a missing destination is rejected with E009")
    func destinationRevoked() async throws {
        let h = try await TransferHarness.make()
        defer { Task { await h.cleanUp() } }
        try FileManager.default.removeItem(at: h.destinationFolder)
        let file = try h.makeFile(megabytes: 0.1)
        await #expect {
            _ = try await h.sender.send(file, gesture: nil) { _ in }
        } throws: { ($0 as? BridgeError)?.code == .destinationPermissionExpired }
    }

    @Test("Replaying a committed transfer ID returns the recorded result and writes nothing new")
    func replayIsIdempotent() async throws {
        let h = try await TransferHarness.make()
        defer { Task { await h.cleanUp() } }
        let file = try h.makeFile(megabytes: 0.5)
        let id = UUID()
        let first = try await h.sender.send(file, transferID: id, gesture: nil) { _ in }
        let again = try await h.sender.send(file, transferID: id, gesture: nil) { _ in }
        #expect(again == first)
        #expect(h.destinationContents == [first.savedFilename])
        #expect(h.events.acceptedCount == 1)
        // The replay is visible as its own event, never as a second `.committed`
        // (which would post a second success notification on the Mac).
        #expect(await h.events.waitFor { $0.replays.count == 1 })
        #expect(h.events.committedURLs.count == 1)
        #expect(h.events.replays.first?.transferID == id)
        #expect(h.events.replays.first?.savedFilename == first.savedFilename)
    }

    @Test("Retrying a failed transfer with the same ID succeeds and saves exactly one file")
    func retrySameID() async throws {
        let h = try await TransferHarness.make()
        defer { Task { await h.cleanUp() } }
        let file = try h.makeFile(megabytes: 0.5, name: "retry.jpeg")
        let id = UUID()
        // First attempt fails on the receiver (corrupt digest via a bogus raw COMPLETE).
        let offer = TransferOffer(
            transferID: id, sourcePeerID: h.phone.identity.peerID, targetPeerID: h.mac.identity.peerID,
            filename: "retry.jpeg", contentType: "public.jpeg", byteCount: 4,
            sha256Hex: String(repeating: "0", count: 64), gesture: nil
        )
        try await h.senderChannel.send(.transferOffer(offer))
        guard case .transferAccept = try await h.senderChannel.receiveControl(timeout: .seconds(5)) else { Issue.record("accept"); return }
        try await h.senderChannel.send(.chunk(ChunkFrame(transferID: id, sequence: 0, offset: 0, payload: Data([1, 2, 3, 4]))))
        try await h.senderChannel.send(.complete(TransferComplete(transferID: id, sha256Hex: offer.sha256Hex, byteCount: 4)))
        #expect(await h.events.waitFor { $0.failures == [.hashMismatch] })
        await h.senderChannel.drainInbox()
        // The retry with the same ID is accepted and commits once.
        let committed = try await h.sender.send(file, transferID: id, gesture: nil) { _ in }
        #expect(committed.savedFilename == "retry.jpeg")
        #expect(h.destinationContents == ["retry.jpeg"])
    }

    @Test("Cancelling the sender cleans up on both sides")
    func senderCancel() async throws {
        let h = try await TransferHarness.make(link: .fake(sender: .init(sendDelay: .milliseconds(5))))
        defer { Task { await h.cleanUp() } }
        let file = try h.makeFile(megabytes: 10)
        let sender = h.sender
        let task = Task { try await sender.send(file, gesture: nil) { _ in } }
        #expect(await h.events.waitFor { $0.acceptedCount == 1 })
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect {
            _ = try await task.value
        } throws: { ($0 as? BridgeError)?.code == .transferCanceled }
        #expect(await h.events.waitFor { $0.failures == [.transferCanceled] })
        #expect(h.destinationContents.isEmpty)
        #expect(h.stagingContents.isEmpty)
    }

    @Test("An offer whose source differs from the authenticated peer is refused")
    func spoofedSource() async throws {
        let h = try await TransferHarness.make()
        defer { Task { await h.cleanUp() } }
        let offer = TransferOffer(
            sourcePeerID: TestPeer.iPhone().identity.peerID, targetPeerID: h.mac.identity.peerID,
            filename: "x.txt", contentType: "public.plain-text", byteCount: 10,
            sha256Hex: String(repeating: "a", count: 64), gesture: nil
        )
        try await h.senderChannel.send(.transferOffer(offer))
        guard case .transferReject(let reject) = try await h.senderChannel.receiveControl(timeout: .seconds(5)) else {
            Issue.record("expected reject"); return
        }
        #expect(reject.reason == .authenticationFailed)
    }
}

@Suite("Storage primitives")
struct StorageTests {
    @Test("Exclusive commit never overwrites and keeps the extension")
    func exclusiveCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...3 {
            let staged = root.appendingPathComponent("staged-\(index)")
            try Data([UInt8(index)]).write(to: staged)
            let url = try FolderDestinationStore.commit(stagedFile: staged, into: root.appendingPathComponent("dest", isDirectory: true).creatingDirectory(), suggestedName: "Report.pdf")
            #expect(url.lastPathComponent == (index == 1 ? "Report.pdf" : "Report \(index).pdf"))
            #expect(try Data(contentsOf: url) == Data([UInt8(index)]))
        }
    }

    @Test("Stale partial files are purged; fresh ones are kept")
    func purge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try StagingArea(directory: root)
        let old = staging.url(for: UUID()), fresh = staging.url(for: UUID())
        try Data([1]).write(to: old)
        try Data([2]).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
        #expect(staging.purge(olderThan: .seconds(86_400)) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("Staged files are private to the owner")
    func permissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-perm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try StagingArea(directory: root).makeWriter(for: UUID(), expectedBytes: 4)
        try writer.append(Data([1, 2, 3, 4]))
        _ = try writer.finish()
        let mode = try FileManager.default.attributesOfItem(atPath: writer.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
        #expect(throws: BridgeError.self) { try StagingArea(directory: root).makeWriter(for: UUID(), expectedBytes: 1).append(Data([1, 2])) }
    }

    @Test("Bounded queue applies backpressure and drains after finish")
    func boundedQueue() async throws {
        let queue = AsyncBoundedQueue<Int>(capacity: 2)
        try await queue.enqueue(1)
        try await queue.enqueue(2)
        let blocked = Task { try await queue.enqueue(3) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await queue.dequeue() == 1)
        try await blocked.value
        await queue.finish()
        #expect(try await queue.dequeue() == 2)
        #expect(try await queue.dequeue() == 3)
        #expect(try await queue.dequeue() == nil)
        await #expect(throws: BridgeError.self) { try await queue.enqueue(4) }
    }
}

extension URL {
    func creatingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
