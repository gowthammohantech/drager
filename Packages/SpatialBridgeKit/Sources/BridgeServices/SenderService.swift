import Foundation
public import Network
public import BridgeCore
public import BridgeModels
public import BridgeNetworking
public import BridgePersistence
public import BridgeSecurity
public import BridgeTransfer
import BridgeDiagnostics

/// Finds peers and their endpoints. `BonjourBrowser` in production; a static
/// locator pointing at loopback listeners in tests.
public protocol PeerLocating: AnyObject, Sendable {
    var peers: AsyncStream<[DiscoveredPeer]> { get }
    var state: AsyncStream<DiscoveryState> { get }
    var currentPeers: [DiscoveredPeer] { get }
    func endpoint(for peerID: String, role: ServiceRole) -> NWEndpoint?
    func start() async
    func stop() async
    func restart() async
}

extension BonjourBrowser: PeerLocating {}

/// Connection status of the iPhone's link to its Mac, for the UI.
public struct LinkStatus: Sendable, Hashable {
    public var state: PeerConnectionState
    public var peer: TrustedPeer?
    public var quality: ConnectionQuality
    public var roundTripTime: TimeInterval?
    public var lastError: BridgeError.Code?

    public init(state: PeerConnectionState = .idle, peer: TrustedPeer? = nil, quality: ConnectionQuality = .unknown, roundTripTime: TimeInterval? = nil, lastError: BridgeError.Code? = nil) {
        self.state = state
        self.peer = peer
        self.quality = quality
        self.roundTripTime = roundTripTime
        self.lastError = lastError
    }

    public var isConnected: Bool { state.isConnected }
}

/// iPhone-side orchestration: discovery, pairing, a supervised session to the
/// preferred Mac (reconnect with backoff, network transitions), sending and
/// metadata-only history. Platform-neutral so it can be tested on macOS.
public actor SenderService {
    public struct Dependencies: Sendable {
        public var identity: DeviceIdentity
        public var device: DeviceInfo
        public var pairSecrets: PairSecretStore
        public var trustedPeers: TrustedPeerStore
        public var history: TransferHistoryStore?
        public var locator: any PeerLocating
        public var limits: TransferLimits
        public var retry: RetryPolicy
        /// The user's preferred Mac (settings). `nil` → most recently paired.
        public var preferredPeerID: @Sendable () async -> PeerID?
        public var watchNetworkPath: Bool

        public init(
            identity: DeviceIdentity,
            device: DeviceInfo,
            pairSecrets: PairSecretStore,
            trustedPeers: TrustedPeerStore,
            history: TransferHistoryStore?,
            locator: any PeerLocating,
            limits: TransferLimits = .default,
            retry: RetryPolicy = RetryPolicy(maxAttempts: .max, initialDelay: .milliseconds(500), maxDelay: .seconds(15)),
            preferredPeerID: @escaping @Sendable () async -> PeerID? = { nil },
            watchNetworkPath: Bool = true
        ) {
            self.identity = identity
            self.device = device
            self.pairSecrets = pairSecrets
            self.trustedPeers = trustedPeers
            self.history = history
            self.locator = locator
            self.limits = limits
            self.retry = retry
            self.preferredPeerID = preferredPeerID
            self.watchNetworkPath = watchNetworkPath
        }
    }

    private struct ActiveSession {
        let peer: TrustedPeer
        let channel: SessionChannel
        let sender: TransferSender
    }

    public nonisolated let status = Broadcaster<LinkStatus>(LinkStatus())
    public nonisolated var discoveredPeers: AsyncStream<[DiscoveredPeer]> { dependencies.locator.peers }
    public nonisolated let dependencies: Dependencies

    private var session: ActiveSession?
    private var supervisor: Task<Void, Never>?
    private var watchers: [Task<Void, Never>] = []
    private var kickWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var pendingKick = false
    private var discoveryState: DiscoveryState = .idle
    private var pairingInProgress = false
    private let pathObserver = PathObserver()
    private let log = BridgeLogger(.session)

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: Lifecycle

    public func start() async {
        guard supervisor == nil else { return }
        await dependencies.locator.start()
        let locator = dependencies.locator
        watchers.append(Task { [weak self] in
            for await _ in locator.peers { await self?.kick() }
        })
        watchers.append(Task { [weak self] in
            for await state in locator.state { await self?.discoveryChanged(state) }
        })
        if dependencies.watchNetworkPath {
            pathObserver.start()
            let updates = pathObserver.updates
            watchers.append(Task { [weak self] in
                var previous: PathObserver.Status = .unknown
                for await status in updates {
                    defer { previous = status }
                    guard previous != .unknown, status != previous else { continue }
                    await self?.networkChanged(status)
                }
            })
        }
        supervisor = Task { [weak self] in await self?.supervise() }
    }

    public func stop() async {
        supervisor?.cancel()
        supervisor = nil
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        pathObserver.stop()
        await dependencies.locator.stop()
        if let session { await session.channel.close() }
        session = nil
        resumeKickWaiters()
        status.send(LinkStatus())
    }

    /// Forces a reconnect attempt now (pull-to-refresh, "Try again").
    public func reconnect() {
        kick()
    }

    // MARK: Pairing

    /// Pairs with a discovered Mac. `decide` shows the comparison code (FR-107).
    public func pair(with peer: DiscoveredPeer, decide: @escaping PairingDecisionHandler) async throws -> TrustedPeer {
        guard !pairingInProgress else { throw BridgeError(.pairingRejected, detail: "pairing already in progress") }
        pairingInProgress = true
        defer { pairingInProgress = false }
        guard let endpoint = dependencies.locator.endpoint(for: peer.id, role: .pairing) else {
            throw BridgeError(.noPeer, detail: "peer is not accepting pairing")
        }
        var current = status.value
        current.state = .pairing
        status.send(current)
        defer { kick() }

        let transport = try await PeerConnector.openPairing(to: endpoint, limits: dependencies.limits)
        let outcome = try await PairingProtocol.runInitiator(
            channel: SessionChannel(transport: transport, configuration: .handshake),
            identity: dependencies.identity,
            device: dependencies.device,
            decide: decide
        )
        // The TXT peer ID was only a hint; refuse if the authenticated key disagrees.
        if let advertised = peer.advertisedPeerID, advertised != outcome.trustedPeer.peerID {
            throw BridgeError(.authenticationFailed, detail: "advertised peer ID does not match paired key")
        }
        try dependencies.pairSecrets.store(psk: outcome.preSharedKey, for: outcome.trustedPeer.peerID)
        try await dependencies.trustedPeers.upsert(outcome.trustedPeer)
        // A fresh pairing replaces any session to an old key.
        if let session, session.peer.peerID == outcome.trustedPeer.peerID {
            await session.channel.close()
            self.session = nil
        }
        log.notice("Stored trust for \(outcome.trustedPeer.peerID.shortDescription)")
        return outcome.trustedPeer
    }

    /// Removes trust and the pair key; closes any session to that Mac.
    public func unpair(_ peerID: PeerID) async throws {
        try dependencies.pairSecrets.remove(peer: peerID)
        try await dependencies.trustedPeers.remove(peerID)
        if let session, session.peer.peerID == peerID {
            await session.channel.close()
            self.session = nil
        }
        kick()
    }

    // MARK: Sending

    /// Sends one file to the connected Mac. One gesture → one call → one transfer
    /// ID (FR-108). Throws `E002`/`E005` when no session is available.
    public func send(
        _ file: OutgoingFile,
        gesture: ExitGesture?,
        transferID: UUID = UUID(),
        progress: @escaping TransferSender.ProgressHandler
    ) async throws -> TransferCommitted {
        guard let session else { throw BridgeError(status.value.peer == nil ? .noPeer : .peerLost) }
        if await session.channel.isClosed {
            kick()
            throw BridgeError(.peerLost)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var record = TransferRecord(
            id: transferID, direction: .outgoing,
            filename: FilenameSanitizer.sanitize(file.filename, contentType: file.contentType),
            contentType: file.contentType, byteCount: size,
            peerID: session.peer.peerID, peerDisplayName: session.peer.displayName, state: .offered
        )
        try? await dependencies.history?.record(record)
        if let gesture {
            DiagnosticsRecorder.shared.record(metric: .gestureToOfferLatency, value: max(0, Date().timeIntervalSince(gesture.firedAt)))
        }
        do {
            let committed = try await session.sender.send(file, transferID: transferID, gesture: gesture, progress: progress)
            record.state = .completed
            record.finishedAt = Date()
            record.filename = committed.savedFilename
            try? await dependencies.history?.record(record)
            return committed
        } catch {
            let bridge = BridgeError.wrap(error, networkContext: true)
            record.state = bridge.code == .transferCanceled ? .canceled : .failed
            record.errorCode = bridge.code
            record.finishedAt = Date()
            try? await dependencies.history?.record(record)
            if bridge.code == .peerLost || bridge.code == .timeout { kick() }
            throw bridge
        }
    }

    // MARK: Supervisor

    private func supervise() async {
        var attempt = 0
        var authFailureStreak = 0
        var searchingSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            guard let target = await currentTarget() else {
                if let session { await session.channel.close(); self.session = nil }
                publish(state: .idle, peer: nil, error: nil)
                await waitForKick(timeout: nil)
                continue
            }

            if let session {
                if session.peer.peerID == target.peerID, !(await session.channel.isClosed) {
                    await waitForKick(timeout: nil)
                    continue
                }
                await session.channel.close()
                self.session = nil
                attempt = max(attempt, 1)
            }

            if case .waiting(.localNetworkDenied) = discoveryState {
                publish(state: .disconnected(reason: .localNetworkDenied), peer: target, error: .localNetworkDenied)
                await waitForKick(timeout: .seconds(10))
                continue
            }

            guard let endpoint = dependencies.locator.endpoint(for: target.peerID.rawValue, role: .session) else {
                let since = searchingSince ?? .now
                searchingSince = since
                let longSearch = ContinuousClock.now - since > .seconds(8)
                publish(
                    state: attempt == 0 ? .discovering : .reconnecting(attempt: attempt),
                    peer: target,
                    error: longSearch ? .noPeer : status.value.lastError
                )
                await waitForKick(timeout: .seconds(2))
                continue
            }
            searchingSince = nil

            publish(state: .authenticating, peer: target, error: nil)
            do {
                let timer = MetricTimer(.connectDuration)
                let active = try await connect(to: target, endpoint: endpoint)
                timer.finish()
                session = active
                attempt = 0
                authFailureStreak = 0
                publish(state: .connected, peer: target, error: nil)
                try? await dependencies.trustedPeers.markSeen(target.peerID, serviceName: nil)
                monitor(active)
                log.notice("Connected to \(target.peerID.shortDescription)")
            } catch {
                let bridge = BridgeError.wrap(error, networkContext: true)
                attempt += 1
                log.error("Connect attempt \(attempt) failed: \(bridge.code.rawValue)")
                if bridge.code == .authenticationFailed {
                    authFailureStreak += 1
                }
                if bridge.code == .authenticationFailed, authFailureStreak > 3 {
                    // Right after pairing the Mac may still be re-keying its listener,
                    // so the first few failures retry quickly. A persistent failure
                    // usually means the Mac no longer trusts us; don't hammer it.
                    publish(state: .disconnected(reason: .authenticationFailed), peer: target, error: .authenticationFailed)
                    await waitForKick(timeout: .seconds(30))
                } else {
                    publish(state: .reconnecting(attempt: attempt), peer: target, error: bridge.code)
                    await waitForKick(timeout: max(dependencies.retry.delay(forAttempt: attempt + 1), .milliseconds(250)))
                }
            }
        }
    }

    private func connect(to target: TrustedPeer, endpoint: NWEndpoint) async throws -> ActiveSession {
        guard let psk = try dependencies.pairSecrets.psk(for: target.peerID) else {
            throw BridgeError(.authenticationFailed, detail: "missing pair key")
        }
        let transport = try await PeerConnector.openSession(
            to: endpoint, identity: dependencies.identity.peerID, preSharedKey: psk, limits: dependencies.limits
        )
        let channel = SessionChannel(transport: transport, configuration: .session)
        do {
            _ = try await SessionAuthenticator.authenticateAsInitiator(
                channel: channel, identity: dependencies.identity, device: dependencies.device, expectedPeer: target
            )
        } catch {
            await channel.close(reason: BridgeError.wrap(error, networkContext: true))
            throw error
        }
        let sender = TransferSender(channel: channel, localPeerID: dependencies.identity.peerID, remotePeerID: target.peerID, limits: dependencies.limits)
        return ActiveSession(peer: target, channel: channel, sender: sender)
    }

    private func monitor(_ active: ActiveSession) {
        let channel = active.channel
        watchers.append(Task { [weak self] in
            for await event in channel.events {
                switch event {
                case .roundTripTime(let rtt):
                    await self?.updateRTT(rtt, for: channel)
                case .closed:
                    await self?.kick()
                }
            }
        })
    }

    private func updateRTT(_ rtt: TimeInterval, for channel: SessionChannel) {
        guard session?.channel === channel else { return }
        var current = status.value
        current.roundTripTime = rtt
        current.quality = ConnectionQuality(roundTripTime: rtt)
        status.send(current)
    }

    private func currentTarget() async -> TrustedPeer? {
        let trusted = await dependencies.trustedPeers.all()
        if let preferred = await dependencies.preferredPeerID(), let match = trusted.first(where: { $0.peerID == preferred }) {
            return match
        }
        return trusted.first
    }

    private func publish(state: PeerConnectionState, peer: TrustedPeer?, error: BridgeError.Code?) {
        var current = status.value
        current.state = state
        current.peer = peer
        current.lastError = error
        if !state.isConnected {
            current.quality = .unknown
            current.roundTripTime = nil
        }
        if current != status.value { status.send(current) }
    }

    private func discoveryChanged(_ state: DiscoveryState) {
        discoveryState = state
        kick()
    }

    private func networkChanged(_ status: PathObserver.Status) async {
        log.info("Network path changed: \(status)")
        if case .satisfied = status {
            await dependencies.locator.restart()
        }
        if let session {
            // Old sockets may be bound to a dead interface; let keepalive or a
            // quick probe decide rather than tearing down a healthy link.
            try? await session.channel.send(.ping(Ping(sequence: 0)))
        }
        kick()
    }

    // MARK: Kick signalling

    private func kick() {
        if kickWaiters.isEmpty {
            pendingKick = true
        } else {
            resumeKickWaiters()
        }
    }

    private func resumeKickWaiters() {
        let waiters = kickWaiters
        kickWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    private func waitForKick(timeout: Duration?) async {
        if pendingKick {
            pendingKick = false
            return
        }
        let id = UUID()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.suspendUntilKick(id: id) }
            if let timeout {
                group.addTask { try? await Task.sleep(for: timeout) }
            }
            await group.next()
            group.cancelAll()
            self.cancelKickWaiter(id)
        }
    }

    private func suspendUntilKick(id: UUID) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { continuation.resume() } else { kickWaiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancelKickWaiter(id) }
        }
    }

    private func cancelKickWaiter(_ id: UUID) {
        kickWaiters.removeValue(forKey: id)?.resume()
    }
}
