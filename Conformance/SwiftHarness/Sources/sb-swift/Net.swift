import Foundation
import Network
import BridgeModels
import BridgeNetworking
import os

/// Small async helpers over raw Network.framework objects.
enum Net {
    static let queue = DispatchQueue(label: "sb-swift.net")

    /// Binds the parameters to HOST:PORT (port 0 = ephemeral), starts a listener
    /// and returns it with the bound port once ready.
    static func listen(
        host: String,
        port: UInt16,
        parameters: NWParameters,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> (NWListener, UInt16) {
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = onConnection
        let once = OSAllocatedUnfairLock(initialState: false)
        let bound: UInt16 = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            @Sendable func finish(_ result: Result<UInt16, any Error>) {
                let first = once.withLock { done in defer { done = true }; return !done }
                if first { continuation.resume(with: result) }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(listener.port?.rawValue ?? 0))
                case .failed(let error): finish(.failure(NetworkErrorMapper.map(error)))
                case .cancelled: finish(.failure(BridgeError(.peerLost, detail: "listener cancelled")))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return (listener, bound)
    }

    /// Starts a connection and waits for `.ready`; TLS failures map to E004.
    static func ready(_ connection: NWConnection, timeout: Duration = .seconds(15)) async throws {
        let once = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            @Sendable func finish(_ result: Result<Void, any Error>) {
                let first = once.withLock { done in defer { done = true }; return !done }
                if first { continuation.resume(with: result) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .waiting(let error):
                    let mapped = NetworkErrorMapper.map(error)
                    if mapped.code == .authenticationFailed { finish(.failure(mapped)) }
                    if case .posix(.ECONNREFUSED) = error { finish(.failure(mapped)) }
                case .failed(let error): finish(.failure(NetworkErrorMapper.map(error)))
                case .cancelled: finish(.failure(BridgeError(.peerLost, detail: "cancelled")))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                finish(.failure(BridgeError(.timeout, detail: "not ready")))
            }
        }
    }

    static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: NetworkErrorMapper.map(error)) } else { continuation.resume() }
            })
        }
    }

    /// Returns nil at EOF.
    static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if let error { continuation.resume(throwing: NetworkErrorMapper.map(error)) }
                else if isComplete { continuation.resume(returning: nil) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }
}
