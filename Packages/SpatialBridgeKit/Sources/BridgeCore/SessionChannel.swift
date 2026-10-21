import Foundation
public import BridgeModels
import BridgeDiagnostics

/// A message-level view of a `FrameTransport` shared by pairing, session
/// authentication and file transfer.
///
/// A single read loop pulls frames from the transport, answers `PING`,
/// records RTT from `PONG`, tracks liveness, and forwards everything else into
/// a small bounded inbox. Because the inbox is bounded, a slow consumer stops
/// the read loop, which stops reading from the socket and lets TCP flow control
/// push back on the sender (ADR-007).
public actor SessionChannel {
    public struct Configuration: Sendable {
        /// Interval between keepalive pings. `nil` disables pings (pairing).
        public var keepaliveInterval: Duration?
        /// Silence after which the peer is considered gone (E005).
        public var deadPeerTimeout: Duration
        /// Frames buffered before the read loop pauses.
        public var inboxCapacity: Int

        public init(keepaliveInterval: Duration? = .seconds(5), deadPeerTimeout: Duration = .seconds(20), inboxCapacity: Int = 8) {
            self.keepaliveInterval = keepaliveInterval
            self.deadPeerTimeout = deadPeerTimeout
            self.inboxCapacity = inboxCapacity
        }

        public static let session = Configuration()
        public static let handshake = Configuration(keepaliveInterval: nil, deadPeerTimeout: .seconds(180))
    }

    public enum Event: Sendable, Hashable {
        case roundTripTime(TimeInterval)
        case closed(BridgeError?)
    }

    public nonisolated let transport: any FrameTransport
    public nonisolated let configuration: Configuration
    public nonisolated let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation
    private let inbox: AsyncBoundedQueue<Frame>
    private var readTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var lastHeard = ContinuousClock.now
    private var pingSequence: UInt32 = 0
    public private(set) var smoothedRoundTripTime: TimeInterval?
    public private(set) var closeReason: BridgeError?
    public private(set) var isClosed = false
    private let log = BridgeLogger(.session)

    public init(transport: any FrameTransport, configuration: Configuration = .session) {
        self.transport = transport
        self.configuration = configuration
        self.inbox = AsyncBoundedQueue(capacity: configuration.inboxCapacity)
        (events, eventContinuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(16))
    }

    /// Starts the read loop (and keepalive if configured). Idempotent.
    public func start() {
        guard readTask == nil, !isClosed else { return }
        lastHeard = .now
        readTask = Task { [weak self] in await self?.readLoop() }
        if let interval = configuration.keepaliveInterval {
            keepaliveTask = Task { [weak self] in await self?.keepaliveLoop(interval: interval) }
        }
    }

    /// Next non-keepalive frame. Throws the close reason once the channel is closed and drained.
    public func receive() async throws -> Frame {
        if readTask == nil { start() }
        guard let frame = try await inbox.dequeue() else {
            throw closeReason ?? BridgeError(.peerLost, detail: "channel closed")
        }
        return frame
    }

    /// Next frame, which must be a control message.
    public func receiveControl() async throws -> ControlMessage {
        let frame = try await receive()
        guard case .control(let data) = frame else {
            throw BridgeError(.protocolMismatch, detail: "unexpected chunk")
        }
        do {
            return try ControlMessageCoder.decode(data)
        } catch {
            throw BridgeError(.protocolMismatch, detail: "undecodable control message")
        }
    }

    /// Next control message with a deadline.
    public func receiveControl(timeout: Duration) async throws -> ControlMessage {
        try await withBridgeTimeout(timeout) { try await self.receiveControl() }
    }

    public func send(_ message: ControlMessage) async throws {
        try await send(.control(try ControlMessageCoder.encode(message)))
    }

    public func send(_ frame: Frame) async throws {
        if isClosed { throw closeReason ?? BridgeError(.peerLost) }
        do {
            try await transport.send(frame)
        } catch {
            let bridge = BridgeError.wrap(error, networkContext: true)
            await close(reason: bridge)
            throw bridge
        }
    }

    /// Drops frames buffered from an earlier exchange.
    public func drainInbox() async {
        await inbox.removeAll()
    }

    /// Closes the channel and the transport. Idempotent.
    public func close(reason: BridgeError? = nil) async {
        guard !isClosed else { return }
        isClosed = true
        closeReason = reason
        keepaliveTask?.cancel()
        readTask?.cancel()
        await inbox.finish(throwing: reason ?? BridgeError(.peerLost, detail: "closed locally"))
        await transport.close()
        eventContinuation.yield(.closed(reason))
        eventContinuation.finish()
        if let reason {
            log.info("Session closed: \(reason.code.rawValue)")
        }
    }

    // MARK: Loops

    private func readLoop() async {
        do {
            for try await frame in transport.incomingFrames {
                lastHeard = .now
                if case .control(let data) = frame, let message = try? ControlMessageCoder.decode(data) {
                    switch message {
                    case .ping(let ping):
                        try await transport.send(.pong(ping))
                        continue
                    case .pong(let pong):
                        recordRoundTrip(sentAt: pong.sentAt)
                        continue
                    default:
                        break
                    }
                }
                try await inbox.enqueue(frame)
            }
            await close(reason: BridgeError(.peerLost, detail: "peer closed the connection"))
        } catch is CancellationError {
            return
        } catch {
            guard !isClosed else { return }
            await close(reason: BridgeError.wrap(error, networkContext: true))
        }
    }

    private func keepaliveLoop(interval: Duration) async {
        while !Task.isCancelled, !isClosed {
            do { try await Task.sleep(for: interval) } catch { return }
            if ContinuousClock.now - lastHeard > configuration.deadPeerTimeout {
                await close(reason: BridgeError(.peerLost, detail: "keepalive timeout"))
                return
            }
            pingSequence &+= 1
            do {
                try await transport.send(.ping(Ping(sequence: pingSequence)))
            } catch {
                await close(reason: BridgeError.wrap(error, networkContext: true))
                return
            }
        }
    }

    private func recordRoundTrip(sentAt: Date) {
        let sample = Date().timeIntervalSince(sentAt)
        guard sample >= 0, sample < 30 else { return }
        let smoothed = smoothedRoundTripTime.map { $0 * 0.8 + sample * 0.2 } ?? sample
        smoothedRoundTripTime = smoothed
        eventContinuation.yield(.roundTripTime(smoothed))
    }
}
