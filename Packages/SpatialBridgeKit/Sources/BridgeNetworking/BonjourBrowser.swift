import Foundation
public import Network
public import BridgeCore
public import BridgeModels
import BridgeDiagnostics
import os

/// Browses `_spatialbridge._tcp` and merges a device's session and pairing
/// instances into one `DiscoveredPeer` (keyed by the advertised peer ID).
///
/// TXT records are untrusted hints: they decide what to *show*, never whom to
/// trust. Duplicate results (one per interface) are collapsed. If nothing
/// compatible appears within `discoveryTimeout`, the state becomes
/// `.waiting(.noPeer)` so the UI can show troubleshooting (PRD §4).
public final class BonjourBrowser: PeerDiscovering, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var serviceType: String
        public var domain: String?
        public var discoveryTimeout: Duration
        public var restartDelay: Duration
        public init(
            serviceType: String = BridgeProtocol.serviceType,
            domain: String? = nil,
            discoveryTimeout: Duration = .seconds(8),
            restartDelay: Duration = .seconds(2)
        ) {
            self.serviceType = serviceType
            self.domain = domain
            self.discoveryTimeout = discoveryTimeout
            self.restartDelay = restartDelay
        }
    }

    private struct Instance: Hashable {
        var name: String
        var endpoint: NWEndpoint
        var txt: [String: String]
    }

    private struct State {
        var browser: NWBrowser?
        var generation = 0
        var instances: [String: Instance] = [:]
        var endpoints: [String: [ServiceRole: NWEndpoint]] = [:]
        var running = false
    }

    public let configuration: Configuration
    private let queue = DispatchQueue(label: "com.gowthammohan.spatialbridge.browser")
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let peerBroadcaster = Broadcaster<[DiscoveredPeer]>([])
    private let stateBroadcaster = Broadcaster<DiscoveryState>(.idle)
    private let log = BridgeLogger(.discovery)
    private let excludedPeerID: PeerID?

    /// - Parameter excluding: this device's own peer ID, so it never lists itself.
    public init(configuration: Configuration = Configuration(), excluding: PeerID? = nil) {
        self.configuration = configuration
        self.excludedPeerID = excluding
    }

    public var peers: AsyncStream<[DiscoveredPeer]> { peerBroadcaster.stream() }
    public var state: AsyncStream<DiscoveryState> { stateBroadcaster.stream() }
    public var currentPeers: [DiscoveredPeer] { peerBroadcaster.value }
    public var currentState: DiscoveryState { stateBroadcaster.value }

    /// Endpoint for connecting to `peerID`'s instance with the given role.
    public func endpoint(for peerID: String, role: ServiceRole) -> NWEndpoint? {
        lock.withLock { $0.endpoints[peerID]?[role] }
    }

    public func start() async {
        let generation: Int? = lock.withLock { state in
            guard !state.running else { return nil }
            state.running = true
            state.generation += 1
            return state.generation
        }
        guard let generation else { return }
        launchBrowser(generation: generation)
    }

    public func stop() async {
        let browser = lock.withLock { state -> NWBrowser? in
            state.running = false
            state.generation += 1
            state.instances.removeAll()
            state.endpoints.removeAll()
            defer { state.browser = nil }
            return state.browser
        }
        browser?.cancel()
        peerBroadcaster.send([])
        stateBroadcaster.send(.idle)
    }

    /// Restarts browsing, e.g. after a network path change.
    public func restart() async {
        await stop()
        await start()
    }

    // MARK: Private

    private func launchBrowser(generation: Int) {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: configuration.serviceType, domain: configuration.domain)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: parameters)
        lock.withLock { $0.browser = browser }
        let timer = MetricTimer(.discoveryDuration)

        browser.stateUpdateHandler = { [weak self] newState in
            guard let self, self.isCurrent(generation) else { return }
            switch newState {
            case .ready:
                self.stateBroadcaster.send(.browsing)
            case .waiting(let error):
                let mapped = NetworkErrorMapper.map(error)
                self.log.error("Browser waiting: \(mapped.code.rawValue)")
                self.stateBroadcaster.send(.waiting(mapped.code))
            case .failed(let error):
                let mapped = NetworkErrorMapper.map(error)
                self.log.error("Browser failed: \(mapped.code.rawValue); restarting")
                self.stateBroadcaster.send(.failed(mapped.code))
                self.scheduleRestart(generation: generation)
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.isCurrent(generation) else { return }
            self.apply(results: results)
            if !self.currentPeers.isEmpty {
                timer.finish()
                if case .waiting(.noPeer) = self.currentState { self.stateBroadcaster.send(.browsing) }
            }
        }
        browser.start(queue: queue)
        log.info("Browsing for \(configuration.serviceType)")

        queue.asyncAfter(deadline: .now() + configuration.discoveryTimeout.timeInterval) { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            if self.currentPeers.isEmpty, case .browsing = self.currentState {
                self.stateBroadcaster.send(.waiting(.noPeer))
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.withLock { $0.running && $0.generation == generation }
    }

    private func scheduleRestart(generation: Int) {
        queue.asyncAfter(deadline: .now() + configuration.restartDelay.timeInterval) { [weak self] in
            guard let self else { return }
            let next: Int? = self.lock.withLock { state in
                guard state.running, state.generation == generation else { return nil }
                state.browser?.cancel()
                state.generation += 1
                return state.generation
            }
            if let next { self.launchBrowser(generation: next) }
        }
    }

    private func apply(results: Set<NWBrowser.Result>) {
        var instances: [String: Instance] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            // Collapse duplicates for the same instance seen on several interfaces.
            if instances[name] == nil {
                instances[name] = Instance(name: name, endpoint: result.endpoint, txt: txt)
            }
        }

        var grouped: [String: (peer: DiscoveredPeer, endpoints: [ServiceRole: NWEndpoint])] = [:]
        for instance in instances.values.sorted(by: { $0.name < $1.name }) {
            let txt = instance.txt
            let advertisedID = txt[BridgeProtocol.TXTKey.peerID].flatMap(PeerID.init(validating:))
            if let excludedPeerID, advertisedID == excludedPeerID { continue }
            let role = txt[BridgeProtocol.TXTKey.role].flatMap(ServiceRole.init(rawValue:)) ?? .session
            let key = advertisedID?.rawValue ?? instance.name
            var entry = grouped[key] ?? (
                DiscoveredPeer(
                    serviceName: instance.name,
                    advertisedPeerID: advertisedID,
                    advertisedDisplayName: txt[BridgeProtocol.TXTKey.displayName].map { String($0.prefix(64)) },
                    platform: txt[BridgeProtocol.TXTKey.platform].flatMap(DevicePlatform.init(rawValue:)),
                    protocolVersion: txt[BridgeProtocol.TXTKey.protocolVersion].flatMap(Int.init),
                    roles: []
                ),
                [:]
            )
            entry.peer.roles.insert(role)
            entry.endpoints[role] = instance.endpoint
            if role == .session { entry.peer.serviceName = instance.name }
            grouped[key] = entry
        }

        let finalInstances = instances
        let endpoints = grouped.mapValues(\.endpoints)
        lock.withLock { state in
            state.instances = finalInstances
            state.endpoints = endpoints
        }
        let previous = Dictionary(peerBroadcaster.value.map { ($0.id, $0.discoveredAt) }, uniquingKeysWith: { first, _ in first })
        let peers = grouped.values.map { entry -> DiscoveredPeer in
            var peer = entry.peer
            if let firstSeen = previous[peer.id] { peer.discoveredAt = firstSeen }
            return peer
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        peerBroadcaster.send(peers)
    }
}
