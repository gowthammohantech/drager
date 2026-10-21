import Foundation
import os

/// Multi-subscriber event stream without replay: each `stream()` receives
/// events sent after it subscribed. Slow subscribers keep the newest events.
public final class EventFanout<Event: Sendable>: Sendable {
    private let continuations = OSAllocatedUnfairLock<[UUID: AsyncStream<Event>.Continuation]>(initialState: [:])
    private let bufferSize: Int

    public init(bufferSize: Int = 64) {
        self.bufferSize = bufferSize
    }

    public func send(_ event: Event) {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.yield(event)
        }
    }

    public func stream() -> AsyncStream<Event> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(bufferSize))
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    public func finish() {
        let all = continuations.withLock { state -> [AsyncStream<Event>.Continuation] in
            defer { state.removeAll() }
            return Array(state.values)
        }
        all.forEach { $0.finish() }
    }
}
