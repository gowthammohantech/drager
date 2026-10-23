import Foundation
import Network
import Security
import Testing
@testable import BridgeModels
@testable import BridgeNetworking

/// ADR-010: sessions must use TLS 1.2 with 0xCCAC only. Network.framework always
/// adds the plain-PSK suites (0x00A8, 0x00A9, 0x00AF, 0x00AE) to the offer, so
/// these loopback tests check the post-handshake guard in `NWFrameTransport.open`.
@Suite("TLS cipher suite pinning", .serialized)
struct TLSCipherSuiteTests {
    private static let identity = PeerID(rawValue: "peer-tls-test")
    private static let psk = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })

    @Test("Only TLS 1.2 with 0xCCAC passes validation")
    func validation() throws {
        try NetworkParameters.validate(suite: 0xCCAC, version: 0x0303)
        for suite: UInt16 in [0x00A8, 0x00A9, 0x00AE, 0x00AF, 0xCCA8, 0xC02B] {
            #expect(throws: BridgeError.self) { try NetworkParameters.validate(suite: suite, version: 0x0303) }
        }
        #expect(throws: BridgeError.self) { try NetworkParameters.validate(suite: 0xCCAC, version: 0x0304) }
        do {
            try NetworkParameters.validate(suite: 0x00A8, version: 0x0303)
            Issue.record("plain PSK accepted")
        } catch {
            #expect(error.code == .authenticationFailed)
        }
    }

    @Test("Production client and server negotiate 0xCCAC over TLS 1.2")
    func negotiatesCCAC() async throws {
        let server = try await Loopback.start(parameters: NetworkParameters.serverSession(keys: [(Self.identity, Self.psk)]))
        defer { server.stop() }
        let client = try await NWFrameTransport.open(
            server.connect(using: NetworkParameters.clientSession(identity: Self.identity, preSharedKey: Self.psk)),
            timeout: .seconds(10)
        )
        defer { Task { await client.close() } }
        let accepted = try await server.nextOutcome()
        let serverTransport = try accepted.get()
        defer { Task { await serverTransport.close() } }

        for connection in [client.connection, serverTransport.connection] {
            let metadata = try #require(connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)
            let negotiated = NetworkParameters.negotiatedTLS(metadata)
            #expect(negotiated.suite == 0xCCAC)
            #expect(negotiated.version == 0x0303)
        }

        // Data flows in both directions.
        let frame = Frame.control(Data("{\"kind\":\"PING\"}".utf8))
        try await client.send(frame)
        var serverFrames = serverTransport.incomingFrames.makeAsyncIterator()
        #expect(try await serverFrames.next() == frame)
    }

    @Test("Server refuses a client that offers only plain-PSK suites")
    func serverRefusesDowngrade() async throws {
        let server = try await Loopback.start(parameters: NetworkParameters.serverSession(keys: [(Self.identity, Self.psk)]))
        defer { server.stop() }
        let connection = server.connect(using: Self.plainPSKOnly())
        // The raw handshake completes (the stack would negotiate 0x00A8)...
        let rawSuite = try await Loopback.readyAndNegotiatedSuite(connection)
        #expect(rawSuite != 0xCCAC)
        // ...but the production server drops it with E004.
        let outcome = try await server.nextOutcome()
        guard case .failure(let error) = outcome else {
            Issue.record("server accepted a plain-PSK session")
            return
        }
        #expect(error.code == .authenticationFailed)
        connection.cancel()
    }

    @Test("Client refuses a server that negotiates a plain-PSK suite")
    func clientRefusesDowngrade() async throws {
        let server = try await Loopback.start(parameters: Self.plainPSKOnly())
        defer { server.stop() }
        do {
            let transport = try await NWFrameTransport.open(
                server.connect(using: NetworkParameters.clientSession(identity: Self.identity, preSharedKey: Self.psk)),
                timeout: .seconds(10)
            )
            await transport.close()
            Issue.record("client accepted a plain-PSK session")
        } catch let error as BridgeError {
            #expect(error.code == .authenticationFailed)
        }
    }

    /// TLS 1.2 PSK options without 0xCCAC. Network.framework then offers (and,
    /// as a server, prefers) only the plain-PSK suites: the downgrade attempt.
    private static func plainPSKOnly() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
        let id = Data(identity.rawValue.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
        sec_protocol_options_add_pre_shared_key(security, key, id)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        sec_protocol_options_set_tls_tickets_enabled(security, false)
        return NWParameters(tls: tls)
    }
}

/// A loopback listener that runs every accepted connection through `NWFrameTransport.open`.
private final class Loopback: @unchecked Sendable {
    let listener: NWListener
    let port: NWEndpoint.Port
    let outcomes: AsyncStream<Result<NWFrameTransport, BridgeError>>

    private init(listener: NWListener, port: NWEndpoint.Port, outcomes: AsyncStream<Result<NWFrameTransport, BridgeError>>) {
        self.listener = listener
        self.port = port
        self.outcomes = outcomes
    }

    static func start(parameters: NWParameters) async throws -> Loopback {
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let (outcomes, continuation) = AsyncStream<Result<NWFrameTransport, BridgeError>>.makeStream()
        listener.newConnectionHandler = { connection in
            Task {
                do {
                    continuation.yield(.success(try await NWFrameTransport.open(connection, timeout: .seconds(10))))
                } catch let error as BridgeError {
                    continuation.yield(.failure(error))
                } catch {
                    continuation.yield(.failure(BridgeError(.peerLost, detail: "\(error)")))
                }
            }
        }
        let queue = DispatchQueue(label: "tls-test.listener")
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { ready in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take(), let port = listener.port { ready.resume(returning: port) }
                case .failed(let error):
                    if once.take() { ready.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return Loopback(listener: listener, port: port, outcomes: outcomes)
    }

    func connect(using parameters: NWParameters) -> NWConnection {
        NWConnection(host: "127.0.0.1", port: port, using: parameters)
    }

    func nextOutcome() async throws -> Result<NWFrameTransport, BridgeError> {
        try await withBridgeTestTimeout(seconds: 15) {
            var iterator = self.outcomes.makeAsyncIterator()
            guard let outcome = await iterator.next() else { throw BridgeError(.peerLost, detail: "listener ended") }
            return outcome
        }
    }

    func stop() { listener.cancel() }

    /// Starts a raw connection (no guard) and returns its negotiated suite once ready.
    static func readyAndNegotiatedSuite(_ connection: NWConnection) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<UInt16, any Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.take() else { return }
                    if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
                        done.resume(returning: NetworkParameters.negotiatedTLS(metadata).suite)
                    } else {
                        done.resume(throwing: BridgeError(.authenticationFailed, detail: "no metadata"))
                    }
                case .waiting(let error), .failed(let error):
                    if once.take() { done.resume(throwing: error) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "tls-test.raw"))
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private func withBridgeTestTimeout<T: Sendable>(seconds: Int, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw BridgeError(.timeout, detail: "test timeout")
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
