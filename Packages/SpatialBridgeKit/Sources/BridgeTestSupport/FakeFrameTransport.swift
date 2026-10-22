import Foundation
public import BridgeCore
public import BridgeModels

/// In-memory duplex transport for deterministic tests. Create a connected pair
/// with `FakeFrameTransport.pair()`. Supports fault injection.
public final class FakeFrameTransport: FrameTransport, @unchecked Sendable {
    public struct Faults: Sendable {
        /// Transform or drop frames on send (`nil` drops). Applied before delivery to the peer.
        public var interceptor: (@Sendable (Frame) -> Frame?)?
        /// Fail the connection after this many frames have been sent.
        public var failAfterFrames: Int?
        /// Artificial per-frame delay.
        public var sendDelay: Duration?

        public init(interceptor: (@Sendable (Frame) -> Frame?)? = nil, failAfterFrames: Int? = nil, sendDelay: Duration? = nil) {
            self.interceptor = interceptor
            self.failAfterFrames = failAfterFrames
            self.sendDelay = sendDelay
        }
    }

    public let name: String
    public private(set) var incomingFrames: AsyncThrowingStream<Frame, any Error>
    private var continuation: AsyncThrowingStream<Frame, any Error>.Continuation
    private weak var peer: FakeFrameTransport?
    private let lock = NSLock()
    private var isClosed = false
    private var sentCount = 0
    public var faults: Faults

    public private(set) var sentFrames: [Frame] = []

    private init(name: String, faults: Faults) {
        self.name = name
        self.faults = faults
        var cont: AsyncThrowingStream<Frame, any Error>.Continuation!
        incomingFrames = AsyncThrowingStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    public static func pair(faultsA: Faults = Faults(), faultsB: Faults = Faults()) -> (FakeFrameTransport, FakeFrameTransport) {
        let a = FakeFrameTransport(name: "A", faults: faultsA)
        let b = FakeFrameTransport(name: "B", faults: faultsB)
        a.peer = b
        b.peer = a
        return (a, b)
    }

    public func send(_ frame: Frame) async throws {
        if let delay = faults.sendDelay {
            try await Task.sleep(for: delay)
        }
        let (closed, count) = lock.withLock { (isClosed, { sentCount += 1; return sentCount }()) }
        if closed { throw BridgeError(.peerLost, detail: "fake transport closed") }
        if let limit = faults.failAfterFrames, count > limit {
            await close()
            throw BridgeError(.peerLost, detail: "fake transport failed after \(limit) frames")
        }
        lock.withLock { sentFrames.append(frame) }
        guard let peer else { throw BridgeError(.peerLost, detail: "no peer") }
        let delivered: Frame?
        if let interceptor = faults.interceptor { delivered = interceptor(frame) } else { delivered = frame }
        if let delivered {
            peer.deliver(delivered)
        }
    }

    private func deliver(_ frame: Frame) {
        let closed = lock.withLock { isClosed }
        guard !closed else { return }
        continuation.yield(frame)
    }

    public func close() async {
        let shouldFinish: Bool = lock.withLock {
            if isClosed { return false }
            isClosed = true
            return true
        }
        guard shouldFinish else { return }
        continuation.finish()
        peer?.peerDidClose()
    }

    private func peerDidClose() {
        let shouldFinish: Bool = lock.withLock {
            if isClosed { return false }
            isClosed = true
            return true
        }
        if shouldFinish {
            continuation.finish()
        }
    }
}

/// Deterministic clock. `sleep` suspends until `advance` moves time past the deadline.
public final class ManualClock: BridgeClock, @unchecked Sendable {
    private var current: Date
    private var waiters: [(deadline: Date, continuation: CheckedContinuation<Void, any Error>)] = []
    private let lock = NSLock()

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    public func now() -> Date {
        lock.withLock { current }
    }

    public func sleep(for duration: Duration) async throws {
        let deadline = now().addingTimeInterval(duration.timeInterval)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    if current >= deadline {
                        continuation.resume()
                    } else {
                        waiters.append((deadline, continuation))
                    }
                }
            }
        } onCancel: {
            let pending = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                let all = waiters.map(\.continuation)
                waiters.removeAll()
                return all
            }
            pending.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    public func advance(by duration: Duration) {
        let due: [CheckedContinuation<Void, any Error>] = lock.withLock {
            current = current.addingTimeInterval(duration.timeInterval)
            let ready = waiters.filter { $0.deadline <= current }.map(\.continuation)
            waiters.removeAll { $0.deadline <= current }
            return ready
        }
        due.forEach { $0.resume() }
    }
}

/// Generates files with deterministic pseudo-random content.
public enum RandomFileFactory {
    public static func make(byteCount: Int, seed: UInt64 = 42, in directory: URL = FileManager.default.temporaryDirectory, name: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name ?? "sb-fixture-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var state = seed | 1
        var remaining = byteCount
        let block = 1 << 20
        while remaining > 0 {
            let count = min(block, remaining)
            var data = Data(count: count)
            data.withUnsafeMutableBytes { buffer in
                for i in 0..<count {
                    // xorshift64*
                    state ^= state >> 12
                    state ^= state << 25
                    state ^= state >> 27
                    buffer[i] = UInt8(truncatingIfNeeded: (state &* 2_685_821_657_736_338_717) >> 56)
                }
            }
            try handle.write(contentsOf: data)
            remaining -= count
        }
        return url
    }
}
