import Foundation
public import Network
import BridgeCore
public import BridgeModels
import BridgeDiagnostics
import os

/// Mac-side listeners (FR-202).
///
/// - A **session** listener (TLS-PSK, one key per trusted iPhone) advertised as
///   `_spatialbridge._tcp` with `role=session`.
/// - A **pairing** listener (plain TCP) advertised with `role=pairing`, only
///   while pairing is enabled.
///
/// Both stop advertising when the user turns Availability off. Listener options
/// are immutable, so the session listener is recreated when the trusted set
/// changes; existing connections are unaffected.
public final class ServiceAdvertiser: @unchecked Sendable {
    public enum Incoming: Sendable {
        case pairing(NWFrameTransport)
        case session(NWFrameTransport)
    }

    public enum State: Sendable, Hashable {
        case stopped
        case advertising(pairing: Bool)
        case failed(BridgeError.Code)
    }

    public struct Configuration: Sendable {
        public var serviceType: String
        public var limits: TransferLimits
        public var maxPendingHandshakes: Int
        public var restartDelay: Duration
        /// Bind to loopback only and skip Bonjour (integration tests).
        public var loopbackOnly: Bool

        public init(
            serviceType: String = BridgeProtocol.serviceType,
            limits: TransferLimits = .default,
            maxPendingHandshakes: Int = 8,
            restartDelay: Duration = .seconds(2),
            loopbackOnly: Bool = false
        ) {
            self.serviceType = serviceType
            self.limits = limits
            self.maxPendingHandshakes = maxPendingHandshakes
            self.restartDelay = restartDelay
            self.loopbackOnly = loopbackOnly
        }
    }

    private struct Store {
        var sessionListener: NWListener?
        var pairingListener: NWListener?
        var sessionKeys: [(identity: PeerID, preSharedKey: Data)] = []
        var pairingEnabled = false
        var running = false
        var generation = 0
        var pending = 0
        var sessionPort: UInt16?
        var pairingPort: UInt16?
    }

    public let configuration: Configuration
    public let incoming: AsyncStream<Incoming>
    private let incomingContinuation: AsyncStream<Incoming>.Continuation
    private let stateBroadcaster = Broadcaster<State>(.stopped)
    private let store = OSAllocatedUnfairLock(initialState: Store())
    private let queue = DispatchQueue(label: "com.gowthammohan.drager.listener")
    private let log = BridgeLogger(.discovery)
    private let device: DeviceInfo

    public init(device: DeviceInfo, configuration: Configuration = Configuration()) {
        self.device = device
        self.configuration = configuration
        (incoming, incomingContinuation) = AsyncStream.makeStream(of: Incoming.self)
    }

    public var state: AsyncStream<State> { stateBroadcaster.stream() }
    public var currentState: State { stateBroadcaster.value }
    /// Bound ports, for loopback tests.
    public var sessionPort: UInt16? { store.withLock { $0.sessionPort } }
    public var pairingPort: UInt16? { store.withLock { $0.pairingPort } }

    public func start(sessionKeys: [(identity: PeerID, preSharedKey: Data)], pairingEnabled: Bool) {
        let generation = store.withLock { store -> Int in
            store.running = true
            store.sessionKeys = sessionKeys
            store.pairingEnabled = pairingEnabled
            store.generation += 1
            return store.generation
        }
        startSessionListener(generation: generation)
        if pairingEnabled { startPairingListener(generation: generation) }
        publishState()
    }

    /// Waits until the current session listener (with the current key set) is
    /// ready, so a peer added by `updateSessionKeys` can connect. Returns `false`
    /// on timeout or when the advertiser is stopped.
    ///
    /// The session listener is rebuilt on every key change and binds a new
    /// ephemeral port, so it can take a moment before a just-paired peer's TLS
    /// handshake succeeds; see `ReceiverService` for what that means for senders.
    public func waitUntilSessionReady(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let (running, port) = store.withLock { ($0.running, $0.sessionPort) }
            guard running else { return false }
            if port != nil { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    public func updateSessionKeys(_ keys: [(identity: PeerID, preSharedKey: Data)]) {
        let (running, generation, old) = store.withLock { store -> (Bool, Int, NWListener?) in
            store.sessionKeys = keys
            let old = store.sessionListener
            store.sessionListener = nil
            store.sessionPort = nil
            return (store.running, store.generation, old)
        }
        old?.cancel()
        if running { startSessionListener(generation: generation) }
    }

    public func setPairingEnabled(_ enabled: Bool) {
        let (running, generation, old) = store.withLock { store -> (Bool, Int, NWListener?) in
            store.pairingEnabled = enabled
            var old: NWListener?
            if !enabled {
                old = store.pairingListener
                store.pairingListener = nil
                store.pairingPort = nil
            }
            return (store.running, store.generation, old)
        }
        old?.cancel()
        if running, enabled, store.withLock({ $0.pairingListener == nil }) {
            startPairingListener(generation: generation)
        }
        publishState()
    }

    public func stop() {
        let listeners = store.withLock { store -> [NWListener] in
            store.running = false
            store.generation += 1
            defer {
                store.sessionListener = nil
                store.pairingListener = nil
                store.sessionPort = nil
                store.pairingPort = nil
            }
            return [store.sessionListener, store.pairingListener].compactMap { $0 }
        }
        listeners.forEach { $0.cancel() }
        stateBroadcaster.send(.stopped)
    }

    // MARK: Private

    private func startSessionListener(generation: Int) {
        let keys = store.withLock { $0.sessionKeys }
        let parameters = NetworkParameters.serverSession(keys: keys)
        guard let listener = makeListener(parameters: parameters, role: .session, generation: generation) else { return }
        store.withLock { $0.sessionListener = listener }
        listener.start(queue: queue)
    }

    private func startPairingListener(generation: Int) {
        guard let listener = makeListener(parameters: NetworkParameters.pairing(), role: .pairing, generation: generation) else { return }
        store.withLock { $0.pairingListener = listener }
        listener.start(queue: queue)
    }

    private func makeListener(parameters: NWParameters, role: ServiceRole, generation: Int) -> NWListener? {
        if configuration.loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            parameters.includePeerToPeer = false
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            log.error("Listener creation failed: \(error)")
            stateBroadcaster.send(.failed(.peerLost))
            return nil
        }
        if !configuration.loopbackOnly {
            var service = NWListener.Service(name: serviceName(for: role), type: configuration.serviceType)
            service.txtRecordObject = NWTXTRecord([
                BridgeProtocol.TXTKey.peerID: device.peerID.rawValue,
                BridgeProtocol.TXTKey.displayName: String(device.displayName.prefix(48)),
                BridgeProtocol.TXTKey.platform: device.platform.rawValue,
                BridgeProtocol.TXTKey.protocolVersion: String(BridgeProtocol.version),
                BridgeProtocol.TXTKey.role: role.rawValue,
            ])
            listener.service = service
        }
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                guard let listener else { return }
                let port = listener.port?.rawValue
                let identifier = ObjectIdentifier(listener)
                let current = self.store.withLock { store -> Bool in
                    // A listener replaced before it became ready must not publish its port.
                    let active = role == .session ? store.sessionListener : store.pairingListener
                    guard let active, ObjectIdentifier(active) == identifier else { return false }
                    if role == .session { store.sessionPort = port } else { store.pairingPort = port }
                    return true
                }
                guard current else { return }
                self.log.info("\(role.rawValue) listener ready")
                self.publishState()
            case .failed(let error):
                let mapped = NetworkErrorMapper.map(error)
                self.log.error("\(role.rawValue) listener failed: \(mapped.code.rawValue)")
                self.stateBroadcaster.send(.failed(mapped.code))
                self.scheduleRestart(role: role, generation: generation)
            case .waiting(let error):
                let mapped = NetworkErrorMapper.map(error)
                if mapped.code == .localNetworkDenied { self.stateBroadcaster.send(.failed(.localNetworkDenied)) }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, role: role)
        }
        return listener
    }

    private func serviceName(for role: ServiceRole) -> String {
        let base = String(device.displayName.prefix(40))
        return role == .session ? base : "\(base) (pairing)"
    }

    private func accept(_ connection: NWConnection, role: ServiceRole) {
        let admitted = store.withLock { store -> Bool in
            guard store.running, store.pending < configuration.maxPendingHandshakes else { return false }
            if role == .pairing && !store.pairingEnabled { return false }
            store.pending += 1
            return true
        }
        guard admitted else {
            connection.cancel()
            return
        }
        let limits = configuration.limits
        Task { [weak self] in
            defer { self?.store.withLock { $0.pending -= 1 } }
            do {
                let transport = try await NWFrameTransport.open(connection, limits: limits, timeout: .seconds(15))
                self?.incomingContinuation.yield(role == .session ? .session(transport) : .pairing(transport))
            } catch {
                // Untrusted TLS identities end here (T-11).
                self?.log.info("Rejected \(role.rawValue) connection: \(BridgeError.wrap(error, networkContext: true).code.rawValue)")
            }
        }
    }

    private func scheduleRestart(role: ServiceRole, generation: Int) {
        queue.asyncAfter(deadline: .now() + configuration.restartDelay.timeInterval) { [weak self] in
            guard let self else { return }
            let shouldRestart = self.store.withLock { store -> Bool in
                guard store.running, store.generation == generation else { return false }
                if role == .session {
                    store.sessionListener?.cancel()
                    store.sessionListener = nil
                    return true
                }
                store.pairingListener?.cancel()
                store.pairingListener = nil
                return store.pairingEnabled
            }
            guard shouldRestart else { return }
            if role == .session { self.startSessionListener(generation: generation) } else { self.startPairingListener(generation: generation) }
        }
    }

    private func publishState() {
        let (running, pairing) = store.withLock { ($0.running, $0.pairingEnabled) }
        guard running else { return }
        if case .failed = stateBroadcaster.value, store.withLock({ $0.sessionPort == nil }) { return }
        stateBroadcaster.send(.advertising(pairing: pairing))
    }
}

/// Watches the network path so callers can reconnect after Wi-Fi changes.
public final class PathObserver: @unchecked Sendable {
    public enum Status: Sendable, Hashable {
        case unknown
        case satisfied(usesWiFi: Bool)
        case unsatisfied
    }

    private let monitor = NWPathMonitor()
    private let broadcaster = Broadcaster<Status>(.unknown)
    private let queue = DispatchQueue(label: "com.gowthammohan.drager.path")

    public init() {}

    public var updates: AsyncStream<Status> { broadcaster.stream() }
    public var current: Status { broadcaster.value }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let status: Status = path.status == .satisfied ? .satisfied(usesWiFi: path.usesInterfaceType(.wifi)) : .unsatisfied
            self?.broadcaster.send(status)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }
}

/// Opens connections to discovered or explicit endpoints.
public enum PeerConnector {
    /// Pairing connection (plain TCP).
    public static func openPairing(to endpoint: NWEndpoint, limits: TransferLimits = .default) async throws -> NWFrameTransport {
        try await NWFrameTransport.open(NWConnection(to: endpoint, using: NetworkParameters.pairing()), limits: limits)
    }

    /// TLS-PSK session connection.
    public static func openSession(
        to endpoint: NWEndpoint,
        identity: PeerID,
        preSharedKey: Data,
        limits: TransferLimits = .default
    ) async throws -> NWFrameTransport {
        let parameters = NetworkParameters.clientSession(identity: identity, preSharedKey: preSharedKey)
        return try await NWFrameTransport.open(NWConnection(to: endpoint, using: parameters), limits: limits)
    }
}
