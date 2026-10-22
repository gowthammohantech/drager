import Foundation
import Testing
@testable import BridgeCore
@testable import BridgeModels
@testable import BridgeTestSupport

@Suite("Fake transport")
struct FakeTransportTests {
    @Test("Frames flow both ways in order and close propagates")
    func duplex() async throws {
        let (a, b) = FakeFrameTransport.pair()
        try await a.send(.ping(Ping(sequence: 1)))
        try await a.send(.ping(Ping(sequence: 2)))
        try await b.send(.pong(Ping(sequence: 1)))

        var bIterator = b.incomingFrames.makeAsyncIterator()
        guard case .control(let first) = try await bIterator.next() else { Issue.record("expected control"); return }
        guard case .ping(let ping1) = try ControlMessageCoder.decode(first) else { Issue.record("expected ping"); return }
        #expect(ping1.sequence == 1)
        guard case .control(let second) = try await bIterator.next(),
              case .ping(let ping2) = try ControlMessageCoder.decode(second) else { Issue.record("expected ping 2"); return }
        #expect(ping2.sequence == 2)

        var aIterator = a.incomingFrames.makeAsyncIterator()
        guard case .control(let pongData) = try await aIterator.next(),
              case .pong = try ControlMessageCoder.decode(pongData) else { Issue.record("expected pong"); return }

        await a.close()
        #expect(try await bIterator.next() == nil)
        await #expect(throws: BridgeError.self) { try await b.send(.ping(Ping(sequence: 3))) }
    }

    @Test("Interceptor can corrupt chunk payloads for hash-mismatch tests")
    func corruption() async throws {
        let (a, b) = FakeFrameTransport.pair(faultsA: .init(interceptor: { frame in
            guard case .chunk(var chunk) = frame else { return frame }
            chunk.payload[0] ^= 0xFF
            return .chunk(chunk)
        }))
        try await a.send(.chunk(ChunkFrame(transferID: UUID(), sequence: 0, offset: 0, payload: Data([1, 2, 3]))))
        var iterator = b.incomingFrames.makeAsyncIterator()
        guard case .chunk(let received) = try await iterator.next() else { Issue.record("expected chunk"); return }
        #expect(received.payload == Data([0xFE, 2, 3]))
    }

    @Test("failAfterFrames simulates a dropped link")
    func dropLink() async throws {
        let (a, b) = FakeFrameTransport.pair(faultsA: .init(failAfterFrames: 2))
        try await a.send(.ping(Ping(sequence: 1)))
        try await a.send(.ping(Ping(sequence: 2)))
        await #expect(throws: BridgeError.self) { try await a.send(.ping(Ping(sequence: 3))) }
        // The peer must stay alive for the duration of the test (transports hold it weakly).
        withExtendedLifetime(b) {}
    }

    @Test("Manual clock drives timeouts deterministically")
    func manualClock() async throws {
        let clock = ManualClock()
        let task = Task {
            try await withBridgeTimeout(.seconds(5), clock: clock) {
                try await clock.sleep(for: .seconds(10))
                return "late"
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        clock.advance(by: .seconds(6))
        await #expect(throws: BridgeError.self) { try await task.value }
    }
}
