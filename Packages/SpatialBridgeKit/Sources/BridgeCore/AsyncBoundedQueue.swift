import Foundation
public import BridgeModels

/// Single-consumer FIFO with a fixed capacity. `enqueue` suspends while the
/// queue is full, which propagates backpressure from a slow consumer (disk
/// writes) to the producer (the network read loop) and from there to TCP.
public actor AsyncBoundedQueue<Element: Sendable> {
    public let capacity: Int
    private var buffer: [Element] = []
    private var head = 0
    private var termination: Termination?
    private var waitingReceiver: (id: UUID, continuation: CheckedContinuation<Element?, any Error>)?
    private var waitingSenders: [(id: UUID, element: Element, continuation: CheckedContinuation<Void, any Error>)] = []

    private enum Termination {
        case finished
        case failed(any Error)
    }

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    private var count: Int { buffer.count - head }

    /// Appends an element, suspending while the queue is full.
    /// Throws if the queue was finished or the calling task is cancelled.
    public func enqueue(_ element: Element) async throws {
        if let termination { throw Self.error(for: termination) }
        if let receiver = waitingReceiver {
            waitingReceiver = nil
            receiver.continuation.resume(returning: element)
            return
        }
        if count < capacity {
            append(element)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waitingSenders.append((id, element, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSender(id) }
        }
    }

    /// Removes the next element. Returns `nil` once the queue is finished and
    /// drained; rethrows the failure passed to `finish(throwing:)` after draining.
    public func dequeue() async throws -> Element? {
        if count > 0 {
            let element = removeFirst()
            admitWaitingSender()
            return element
        }
        if let termination {
            switch termination {
            case .finished: return nil
            case .failed(let error): throw error
            }
        }
        precondition(waitingReceiver == nil, "AsyncBoundedQueue supports a single consumer")
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Element?, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waitingReceiver = (id, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelReceiver(id) }
        }
    }

    /// Ends the queue. Buffered elements are still delivered; blocked senders fail.
    public func finish(throwing error: (any Error)? = nil) {
        guard termination == nil else { return }
        termination = error.map { .failed($0) } ?? .finished
        let senders = waitingSenders
        waitingSenders.removeAll()
        let terminationError = Self.error(for: termination!)
        for sender in senders { sender.continuation.resume(throwing: terminationError) }
        if let receiver = waitingReceiver, count == 0 {
            waitingReceiver = nil
            if let error { receiver.continuation.resume(throwing: error) } else { receiver.continuation.resume(returning: nil) }
        }
    }

    public var isFinished: Bool { termination != nil }

    /// Discards buffered elements (used between transfers to drop stale frames).
    public func removeAll() {
        buffer.removeAll(keepingCapacity: true)
        head = 0
        while count < capacity, !waitingSenders.isEmpty { admitWaitingSender() }
    }

    // MARK: Private

    private func append(_ element: Element) {
        buffer.append(element)
    }

    private func removeFirst() -> Element {
        let element = buffer[head]
        head += 1
        if head > 64, head * 2 > buffer.count {
            buffer.removeFirst(head)
            head = 0
        }
        return element
    }

    private func admitWaitingSender() {
        guard !waitingSenders.isEmpty, count < capacity else { return }
        let sender = waitingSenders.removeFirst()
        append(sender.element)
        sender.continuation.resume()
    }

    private func cancelSender(_ id: UUID) {
        guard let index = waitingSenders.firstIndex(where: { $0.id == id }) else { return }
        let sender = waitingSenders.remove(at: index)
        sender.continuation.resume(throwing: CancellationError())
    }

    private func cancelReceiver(_ id: UUID) {
        guard let receiver = waitingReceiver, receiver.id == id else { return }
        waitingReceiver = nil
        receiver.continuation.resume(throwing: CancellationError())
    }

    private static func error(for termination: Termination) -> any Error {
        switch termination {
        case .finished: BridgeError(.peerLost, detail: "queue finished")
        case .failed(let error): error
        }
    }
}

/// Resolves trusted peers. Implemented by `TrustedPeerStore` (BridgePersistence).
public protocol TrustDirectory: Sendable {
    func trustedPeer(_ id: PeerID) async -> TrustedPeer?
    func allTrusted() async -> [TrustedPeer]
}
