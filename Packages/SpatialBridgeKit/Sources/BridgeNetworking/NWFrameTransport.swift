import Foundation
public import Network
public import BridgeCore
public import BridgeModels
import BridgeDiagnostics
import os

/// `FrameTransport` over an `NWConnection`.
///
/// Reads are pull-based: `incomingFrames` asks the connection for more bytes
/// only when the consumer wants the next frame, so a slow consumer leaves data
/// in the kernel and TCP flow control throttles the peer. Sends complete when
/// Network.framework reports `.contentProcessed`, which is the backpressure
/// point for senders (ADR-007).
public final class NWFrameTransport: FrameTransport, @unchecked Sendable {
    public let connection: NWConnection
    public let limits: TransferLimits
    public let incomingFrames: AsyncThrowingStream<Frame, any Error>

    private struct State {
        var decoder: FrameDecoder
        var closed = false
        var failure: BridgeError?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let queue: DispatchQueue
    private static let readSize = 64 * 1024

    private init(connection: NWConnection, queue: DispatchQueue, limits: TransferLimits) {
        self.connection = connection
        self.queue = queue
        self.limits = limits
        let state = OSAllocatedUnfairLock(initialState: State(decoder: FrameDecoder(limits: limits)))
        self.state = state
        let reader = Reader(connection: connection, state: state)
        incomingFrames = AsyncThrowingStream(unfolding: { try await reader.next() })
    }

    /// Starts `connection` and waits until it is ready.
    ///
    /// TLS failures (unknown PSK identity, bad MAC) surface as `.waiting` on the
    /// client and are mapped to E004 immediately instead of waiting forever.
    /// A TLS connection that negotiated anything but TLS 1.2 with 0xCCAC is
    /// cancelled with E004 when it becomes ready (ADR-010).
    public static func open(
        _ connection: NWConnection,
        limits: TransferLimits = .default,
        timeout: Duration = .seconds(15)
    ) async throws -> NWFrameTransport {
        let queue = DispatchQueue(label: "com.gowthammohan.spatialbridge.connection")
        let transport = NWFrameTransport(connection: connection, queue: queue, limits: limits)
        try await transport.waitUntilReady(timeout: timeout)
        return transport
    }

    private func waitUntilReady(timeout: Duration) async throws {
        let once = OSAllocatedUnfairLock(initialState: false)
        let connection = connection
        let stateRef = state
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    @Sendable func finish(_ result: Result<Void, BridgeError>) {
                        let first = once.withLock { done in
                            defer { done = true }
                            return !done
                        }
                        guard first else { return }
                        continuation.resume(with: result.mapError { $0 as any Error })
                    }
                    connection.stateUpdateHandler = { newState in
                        switch newState {
                        case .ready:
                            // ADR-010: only TLS 1.2 + 0xCCAC. Network.framework also
                            // offers and accepts plain-PSK suites, so check here before
                            // any application data flows.
                            do throws(BridgeError) {
                                try NetworkParameters.validateNegotiatedTLS(connection)
                                finish(.success(()))
                            } catch {
                                finish(.failure(error))
                            }
                        case .waiting(let error):
                            let mapped = NetworkErrorMapper.map(error)
                            // Authentication and policy failures will never resolve by waiting.
                            if mapped.code == .authenticationFailed || mapped.code == .localNetworkDenied {
                                finish(.failure(mapped))
                            } else if case .posix(.ECONNREFUSED) = error {
                                // Nothing is listening; the caller's retry policy decides what's next.
                                finish(.failure(mapped))
                            }
                        case .failed(let error):
                            finish(.failure(NetworkErrorMapper.map(error)))
                        case .cancelled:
                            finish(.failure(BridgeError(.peerLost, detail: "connection cancelled")))
                        default:
                            break
                        }
                        if case .failed = newState { stateRef.withLock { $0.closed = true } }
                        if case .cancelled = newState { stateRef.withLock { $0.closed = true } }
                    }
                    connection.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                        finish(.failure(BridgeError(.timeout, detail: "connection not ready")))
                    }
                }
            } onCancel: {
                connection.cancel()
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    public func send(_ frame: Frame) async throws {
        if let failure = state.withLock({ $0.closed ? ($0.failure ?? BridgeError(.peerLost, detail: "closed")) : nil }) {
            throw failure
        }
        let data: Data
        do {
            data = try FrameCodec.encode(frame, limits: limits)
        } catch let error as FrameCodec.CodecError {
            throw error.bridgeError
        }
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: NetworkErrorMapper.map(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() async {
        let shouldCancel = state.withLock { state in
            defer { state.closed = true }
            return !state.closed
        }
        if shouldCancel { connection.cancel() }
    }

    /// The remote endpoint once connected (for diagnostics only; never trusted).
    public var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }

    // MARK: - Reader

    /// Pull-based frame reader driving `incomingFrames`.
    private final class Reader: Sendable {
        let connection: NWConnection
        let state: OSAllocatedUnfairLock<State>

        init(connection: NWConnection, state: OSAllocatedUnfairLock<State>) {
            self.connection = connection
            self.state = state
        }

        func next() async throws -> Frame? {
            while true {
                let decoded: Result<Frame?, BridgeError> = state.withLock { state in
                    do {
                        return .success(try state.decoder.next())
                    } catch let error as FrameCodec.CodecError {
                        return .failure(error.bridgeError)
                    } catch {
                        return .failure(BridgeError(.protocolMismatch, detail: "frame decode"))
                    }
                }
                switch decoded {
                case .success(let frame?):
                    return frame
                case .failure(let error):
                    fail(error)
                    throw error
                case .success(nil):
                    break
                }
                if state.withLock({ $0.closed }) { return nil }
                guard let bytes = try await receive() else { return nil }
                state.withLock { $0.decoder.append(bytes) }
            }
        }

        private func receive() async throws -> Data? {
            let connection = connection
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: NWFrameTransport.readSize) { data, _, isComplete, error in
                        if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else if let error {
                            if case .posix(let code) = error, code == .ECANCELED {
                                continuation.resume(returning: nil)
                            } else {
                                continuation.resume(throwing: NetworkErrorMapper.map(error))
                            }
                        } else if isComplete {
                            continuation.resume(returning: nil)
                        } else {
                            continuation.resume(returning: Data())
                        }
                    }
                }
            } onCancel: {
                connection.cancel()
            }
        }

        private func fail(_ error: BridgeError) {
            state.withLock { state in
                state.closed = true
                state.failure = error
            }
            connection.cancel()
        }
    }
}

/// Maps Network.framework errors onto the product's error vocabulary.
public enum NetworkErrorMapper {
    /// `kDNSServiceErr_PolicyDenied`: Local Network privacy denied.
    static let dnsPolicyDenied: Int32 = -65570
    /// Secure Transport statuses seen for PSK failures.
    static let tlsAuthenticationStatuses: Set<OSStatus> = [
        -9864, // errSSLUnknownPSKIdentity
        -9820, // errSSLBadRecordMac
        -9846, // errSSLDecryptionFail / bad MAC on server
        -9858, // errSSLHandshakeFail
        -9825, // errSSLPeerBadRecordMac
        -9806, // errSSLClosedAbort during handshake
    ]

    public static func map(_ error: NWError) -> BridgeError {
        switch error {
        case .dns(let code) where code == dnsPolicyDenied:
            return BridgeError(.localNetworkDenied, detail: "DNS policy denied")
        case .tls(let status) where tlsAuthenticationStatuses.contains(status):
            return BridgeError(.authenticationFailed, detail: "TLS \(status)")
        case .tls(let status):
            return BridgeError(.authenticationFailed, detail: "TLS \(status)")
        case .posix(let code):
            switch code {
            case .ECONNREFUSED, .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH:
                return BridgeError(.noPeer, detail: "posix \(code.rawValue)")
            case .ETIMEDOUT:
                return BridgeError(.timeout, detail: "posix timeout")
            default:
                return BridgeError(.peerLost, detail: "posix \(code.rawValue)")
            }
        case .dns(let code):
            return BridgeError(.noPeer, detail: "dns \(code)")
        default:
            return BridgeError(.peerLost, detail: "\(error)")
        }
    }
}
