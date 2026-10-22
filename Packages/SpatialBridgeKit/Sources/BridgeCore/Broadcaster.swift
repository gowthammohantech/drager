import Foundation
import os

/// Multi-subscriber value stream. Each call to `stream()` returns a new
/// `AsyncStream` that immediately yields the current value and then every
/// subsequent update. Subscribers that go away are removed automatically.
public final class Broadcaster<Value: Sendable>: Sendable {
    private struct State {
        var value: Value
        var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
        var finished = false
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(_ initial: Value) {
        state = OSAllocatedUnfairLock(initialState: State(value: initial))
    }

    public var value: Value { state.withLock { $0.value } }

    public func send(_ value: Value) {
        let targets = state.withLock { state -> [AsyncStream<Value>.Continuation] in
            state.value = value
            return Array(state.continuations.values)
        }
        for continuation in targets { continuation.yield(value) }
    }

    /// Applies `transform` atomically and broadcasts the result.
    public func update(_ transform: @Sendable (inout Value) -> Void) {
        let (value, targets) = state.withLock { state -> (Value, [AsyncStream<Value>.Continuation]) in
            transform(&state.value)
            return (state.value, Array(state.continuations.values))
        }
        for continuation in targets { continuation.yield(value) }
    }

    public func stream() -> AsyncStream<Value> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
        let current: Value? = state.withLock { state in
            guard !state.finished else { return nil }
            state.continuations[id] = continuation
            return state.value
        }
        if let current {
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
            }
        } else {
            continuation.finish()
        }
        return stream
    }

    public func finish() {
        let targets = state.withLock { state -> [AsyncStream<Value>.Continuation] in
            state.finished = true
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        for continuation in targets { continuation.finish() }
    }
}
