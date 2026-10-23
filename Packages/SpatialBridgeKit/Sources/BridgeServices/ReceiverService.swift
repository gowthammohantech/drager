import Foundation
public import BridgeCore
public import BridgeModels
public import BridgeNetworking
public import BridgePersistence
public import BridgeSecurity
public import BridgeTransfer
import BridgeDiagnostics

/// Pairing activity on the Mac, for the pairing sheet and notifications.
public enum PairingActivity: Sendable {
    case succeeded(TrustedPeer)
    case failed(BridgeError)
}

/// Mac-side orchestration: advertising (FR-202), pairing approval, session
/// authentication, receiving (FR-203…FR-209) and metadata-only history.
public actor ReceiverService {
    public struct Dependencies: Sendable {
        public var identity: DeviceIdentity
        public var device: DeviceInfo
        public var pairSecrets: PairSecretStore
        public var trustedPeers: TrustedPeerStore
        public var history: TransferHistoryStore?
        public var staging: StagingArea
        public var destination: any DestinationStore
        public var policy: TransferPolicy
        public var advertiser: ServiceAdvertiser.Configuration
        public var rateLimiter: PairingRateLimiter

        public init(
            identity: DeviceIdentity,
            device: DeviceInfo,
            pairSecrets: PairSecretStore,
            trustedPeers: TrustedPeerStore,
            history: TransferHistoryStore?,
            staging: StagingArea,
            destination: any DestinationStore,
            policy: TransferPolicy = .default,
            advertiser: ServiceAdvertiser.Configuration = .init(),
            rateLimiter: PairingRateLimiter = PairingRateLimiter()
        ) {
            self.identity = identity
            self.device = device
            self.pairSecrets = pairSecrets
            self.trustedPeers = trustedPeers
            self.history = history
            self.staging = staging
            self.destination = destination
            self.policy = policy
            self.advertiser = advertiser
            self.rateLimiter = rateLimiter
        }
    }

    private struct LiveSession {
        let peer: TrustedPeer
        let channel: SessionChannel
    }

    public nonisolated let dependencies: Dependencies
    public nonisolated let events = EventFanout<ReceiverEvent>()
    public nonisolated let pairingActivity = EventFanout<PairingActivity>()
    public nonisolated let connectedPeers = Broadcaster<[TrustedPeer]>([])
    public nonisolated let advertiser: ServiceAdvertiser

    private let ledger = TransferOutcomeLedger()
    private var sessions: [UUID: LiveSession] = [:]
    private var acceptLoop: Task<Void, Never>?
    private var historyLoop: Task<Void, Never>?
    private var pairingDecision: PairingDecisionHandler = { _ in false }
    private var pairingInProgress = false
    private var available = false
    private var allowPairing = false
    private let log = BridgeLogger(.session)

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
        self.advertiser = ServiceAdvertiser(device: dependencies.device, configuration: dependencies.advertiser)
    }

    /// Supplies the UI that asks the Mac user to compare codes.
    public func setPairingDecisionHandler(_ handler: @escaping PairingDecisionHandler) {
        pairingDecision = handler
    }

    public func start(available: Bool, allowPairing: Bool) async {
        guard acceptLoop == nil else {
            await setAvailable(available)
            await setAllowPairing(allowPairing)
            return
        }
        let removed = dependencies.staging.purge(olderThan: dependencies.policy.limits.stagingRetention)
        if removed > 0 { log.notice("Purged \(removed) stale partial file(s)") }

        let incoming = advertiser.incoming
        acceptLoop = Task { [weak self] in
            for await connection in incoming {
                guard let self else { return }
                switch connection {
                case .pairing(let transport):
                    Task { await self.handlePairing(transport) }
                case .session(let transport):
                    Task { await self.handleSession(transport) }
                }
            }
        }
        let stream = events.stream()
        historyLoop = Task { [weak self] in
            for await event in stream { await self?.recordHistory(event) }
        }
        self.allowPairing = allowPairing
        await setAvailable(available)
    }

    public func stop() async {
        advertiser.stop()
        acceptLoop?.cancel()
        historyLoop?.cancel()
        acceptLoop = nil
        historyLoop = nil
        for session in sessions.values { await session.channel.close() }
        sessions.removeAll()
        connectedPeers.send([])
    }

    /// FR-202: advertise only while the user wants to be discoverable.
    public func setAvailable(_ isAvailable: Bool) async {
        available = isAvailable
        if isAvailable {
            advertiser.start(sessionKeys: await sessionKeys(), pairingEnabled: allowPairing)
        } else {
            advertiser.stop()
            for session in sessions.values { await session.channel.close(reason: BridgeError(.peerLost, detail: "receiver unavailable")) }
        }
    }

    public func setAllowPairing(_ allow: Bool) async {
        allowPairing = allow
        if available { advertiser.setPairingEnabled(allow) }
    }

    /// Revokes trust (T-02 for future connections) and drops live sessions.
    public func unpair(_ peerID: PeerID) async throws {
        try dependencies.pairSecrets.remove(peer: peerID)
        try await dependencies.trustedPeers.remove(peerID)
        for (id, session) in sessions where session.peer.peerID == peerID {
            await session.channel.close(reason: BridgeError(.authenticationFailed, detail: "unpaired"))
            sessions.removeValue(forKey: id)
        }
        publishConnected()
        if available { advertiser.updateSessionKeys(await sessionKeys()) }
    }

    // MARK: Connections

    private func handlePairing(_ transport: NWFrameTransport) async {
        guard !pairingInProgress else {
            await transport.close()
            return
        }
        pairingInProgress = true
        defer { pairingInProgress = false }
        let channel = SessionChannel(transport: transport, configuration: .handshake)
        do {
            let outcome = try await PairingProtocol.runResponder(
                channel: channel,
                identity: dependencies.identity,
                device: dependencies.device,
                rateLimiter: dependencies.rateLimiter,
                decide: pairingDecision
            )
            try dependencies.pairSecrets.store(psk: outcome.preSharedKey, for: outcome.trustedPeer.peerID)
            try await dependencies.trustedPeers.upsert(outcome.trustedPeer)
            // Re-key window: the initiator finishes as soon as it has our
            // PAIR_CONFIRM and may connect before we have verified its confirm,
            // stored the PSK and rebuilt the session listener (Network.framework
            // fixes the PSK set per listener, and the rebuilt listener has a new
            // port that Bonjour must re-announce). That first session fails
            // (unknown PSK identity → E004, or refused/unresolved → retry) and the
            // sender's reconnect loop gets in once the new listener is up. Only
            // report success once that listener is ready, so "Paired" on the Mac
            // means the peer's sessions are accepted.
            if available {
                advertiser.updateSessionKeys(await sessionKeys())
                if !(await advertiser.waitUntilSessionReady()) { log.error("Session listener not ready after pairing") }
            }
            pairingActivity.send(.succeeded(outcome.trustedPeer))
        } catch {
            pairingActivity.send(.failed(BridgeError.wrap(error, networkContext: true)))
        }
    }

    private func handleSession(_ transport: NWFrameTransport) async {
        let channel = SessionChannel(transport: transport, configuration: .session)
        let peer: TrustedPeer
        do {
            peer = try await SessionAuthenticator.authenticateAsResponder(
                channel: channel, identity: dependencies.identity, device: dependencies.device, trust: dependencies.trustedPeers
            ).peer
        } catch {
            await channel.close(reason: BridgeError.wrap(error, networkContext: true))
            log.info("Session refused: \(BridgeError.wrap(error, networkContext: true).code.rawValue)")
            return
        }
        // Availability may have been switched off while we were authenticating.
        guard available else {
            await channel.close(reason: BridgeError(.peerLost, detail: "receiver unavailable"))
            return
        }
        // One session per iPhone: a reconnect replaces the stale one.
        for (id, existing) in sessions where existing.peer.peerID == peer.peerID {
            await existing.channel.close()
            sessions.removeValue(forKey: id)
        }
        let id = UUID()
        sessions[id] = LiveSession(peer: peer, channel: channel)
        publishConnected()
        try? await dependencies.trustedPeers.markSeen(peer.peerID, serviceName: nil)
        log.notice("Session with \(peer.peerID.shortDescription) authenticated")

        let events = events
        let receiver = TransferReceiver(
            channel: channel,
            peer: peer,
            localPeerID: dependencies.identity.peerID,
            destination: dependencies.destination,
            staging: dependencies.staging,
            ledger: ledger,
            configuration: .init(policy: dependencies.policy),
            emit: { events.send($0) }
        )
        await receiver.run()
        await channel.close()
        if sessions[id] != nil {
            sessions.removeValue(forKey: id)
            publishConnected()
        }
    }

    private func sessionKeys() async -> [(identity: PeerID, preSharedKey: Data)] {
        var keys: [(identity: PeerID, preSharedKey: Data)] = []
        for peer in await dependencies.trustedPeers.all() {
            if let psk = try? dependencies.pairSecrets.psk(for: peer.peerID) {
                keys.append((peer.peerID, psk))
            }
        }
        return keys
    }

    private func publishConnected() {
        var seen = Set<PeerID>()
        let peers = sessions.values.map(\.peer).filter { seen.insert($0.peerID).inserted }
        connectedPeers.send(peers.sorted { $0.displayName < $1.displayName })
    }

    private func recordHistory(_ event: ReceiverEvent) async {
        guard let history = dependencies.history else { return }
        func record(_ offer: TransferOffer, peer: TrustedPeer, state: TransferState, error: BridgeError.Code? = nil, saved: URL? = nil) async {
            let existing = await history.all().first { $0.id == offer.transferID }
            var item = existing ?? TransferRecord(
                id: offer.transferID, direction: .incoming, filename: offer.filename, contentType: offer.contentType,
                byteCount: offer.byteCount, peerID: peer.peerID, peerDisplayName: peer.displayName
            )
            item.state = state
            item.errorCode = error
            if state.isTerminal { item.finishedAt = Date() }
            if let saved {
                item.savedPath = saved.path
                item.filename = saved.lastPathComponent
            }
            try? await history.record(item)
        }
        switch event {
        case .accepted(let offer, let peer): await record(offer, peer: peer, state: .streaming)
        case .committed(let offer, let url, let peer): await record(offer, peer: peer, state: .completed, saved: url)
        case .rejected(let offer, let reason, let peer): await record(offer, peer: peer, state: .failed, error: reason.code)
        case .failed(let offer, let reason, let peer):
            await record(offer, peer: peer, state: reason.code == .transferCanceled ? .canceled : .failed, error: reason.code)
        case .progress, .verifying, .replayed: break // a replay leaves the original record as is
        }
    }
}
