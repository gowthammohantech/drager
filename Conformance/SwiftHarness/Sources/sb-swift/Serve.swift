import Foundation
import Network
import BridgeCore
import BridgeModels
import BridgeNetworking
import BridgeSecurity
import BridgeTransfer

/// `serve`: receiver role (like the Mac) on 127.0.0.1 with no Bonjour.
///
/// `ReceiverService` always advertises over Bonjour via `ServiceAdvertiser`
/// and rebinds its session listener to a new port when keys change, so the
/// harness drives the lower-level pieces directly: its own pairing and
/// session listeners, `PairingProtocol.runResponder`,
/// `SessionAuthenticator.authenticateAsResponder` and `TransferReceiver`.
/// The session listener is rebuilt on the **same port** after each pairing,
/// because Network.framework fixes the PSK set when a listener is created.
actor Server {
    let state: HarnessState
    let host: String
    let approve: Bool
    let timeouts: HarnessTimeouts
    let destination: FolderDestinationStore
    let staging: StagingArea
    let ledger = TransferOutcomeLedger()
    let rateLimiter = PairingRateLimiter()
    let unpairs: UnpairWatcher
    private var pairingListener: NWListener?
    private var sessionListener: NWListener?
    private var sessionPort: UInt16 = 0
    private var pairingInProgress = false

    init(state: HarnessState, host: String, approve: Bool, timeouts: HarnessTimeouts, dest: URL) throws {
        self.state = state
        self.host = host
        self.approve = approve
        self.timeouts = timeouts
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        destination = FolderDestinationStore(folder: dest)
        staging = try StagingArea(directory: state.directory.appendingPathComponent("staging", isDirectory: true))
        unpairs = UnpairWatcher(state: state)
    }

    func start(pairingPort: UInt16, sessionPort: UInt16) async throws -> (UInt16, UInt16) {
        // Like ReceiverService at launch: drop partial files left over from earlier runs (24 h retention).
        staging.purge(olderThan: timeouts.limits.stagingRetention)
        let (pairing, pPort) = try await Net.listen(host: host, port: pairingPort, parameters: NetworkParameters.pairing()) { [weak self] connection in
            Task { await self?.handlePairing(connection) }
        }
        pairingListener = pairing
        self.sessionPort = sessionPort
        try await restartSessionListener()
        return (pPort, self.sessionPort)
    }

    /// (Re)binds the TLS-PSK session listener with the current trusted keys.
    private func restartSessionListener() async throws {
        sessionListener?.cancel()
        sessionListener = nil
        let keys = await state.sessionKeys()
        var lastError: (any Error)?
        for _ in 0..<50 {
            do {
                let (listener, port) = try await Net.listen(
                    host: host, port: sessionPort, parameters: NetworkParameters.serverSession(keys: keys)
                ) { [weak self] connection in
                    Task { await self?.handleSession(connection) }
                }
                sessionListener = listener
                sessionPort = port
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        throw lastError ?? BridgeError(.peerLost, detail: "session listener")
    }

    private func handlePairing(_ connection: NWConnection) async {
        guard !pairingInProgress else {
            connection.cancel()
            return
        }
        pairingInProgress = true
        defer { pairingInProgress = false }
        do {
            let transport = try await NWFrameTransport.open(connection, limits: timeouts.limits)
            let channel = SessionChannel(transport: transport, configuration: .handshake)
            let outcome = try await PairingProtocol.runResponder(
                channel: channel, identity: state.identity, device: state.device(platform: .macOS),
                rateLimiter: rateLimiter, timeouts: timeouts.pairing, decide: Decision.handler(approve: approve)
            )
            try await state.remember(outcome)
            await unpairs.add(outcome.trustedPeer.peerID)
            try await restartSessionListener()
            PairCommands.paired(outcome)
        } catch {
            Out.event("pairFailed", ["code": bridgeCode(error).rawValue])
        }
    }

    /// Runs until cancelled, applying unpairs made by other processes on this state.
    func watchUnpairs() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: UnpairWatcher.interval)
            for peer in await unpairs.poll() {
                await applyUnpair(peer)
            }
        }
    }

    /// Another process ran `unpair` on our state: drop the cached trust entry and rebind the
    /// session listener without the PSK, so the next session from that peer fails E004.
    func applyUnpair(_ peer: PeerID) async {
        try? await state.trusted.remove(peer)
        do {
            try await restartSessionListener()
        } catch {
            Out.error(bridgeCode(error))
        }
        Out.event("unpaired", ["peerID": peer.rawValue])
    }

    private func handleSession(_ connection: NWConnection) async {
        let channel: SessionChannel
        let peer: TrustedPeer
        do {
            let transport = try await NWFrameTransport.open(connection, limits: timeouts.limits, timeout: .seconds(30))
            channel = SessionChannel(transport: transport, configuration: .session)
            do {
                peer = try await SessionAuthenticator.authenticateAsResponder(
                    channel: channel, identity: state.identity, device: state.device(platform: .macOS), trust: state.trusted
                ).peer
            } catch {
                await channel.close(reason: BridgeError.wrap(error, networkContext: true))
                throw error
            }
        } catch {
            Out.error(bridgeCode(error))
            return
        }
        Out.event("sessionReady", ["peerID": peer.peerID.rawValue])
        let receiver = TransferReceiver(
            channel: channel,
            peer: peer,
            localPeerID: state.identity.peerID,
            destination: destination,
            staging: staging,
            ledger: ledger,
            configuration: .init(policy: TransferPolicy(limits: timeouts.limits)),
            emit: Server.report
        )
        await receiver.run()
        await channel.close()
    }

    /// Receiver events → JSON lines. Never includes the filename or saved path.
    @Sendable nonisolated static func report(_ event: ReceiverEvent) {
        switch event {
        case .progress(_, let received, _):
            Out.event("progress", ["offset": Int(received)])
        case .committed(let offer, _, _):
            Out.event("committed", [
                "transferID": offer.transferID.uuidString,
                "byteCount": Int(offer.byteCount),
                "sha256Hex": offer.sha256Hex.lowercased(),
            ])
        case .replayed(let offer, _, _):
            Out.event("committed", [
                "transferID": offer.transferID.uuidString,
                "byteCount": Int(offer.byteCount),
                "sha256Hex": offer.sha256Hex.lowercased(),
                "replayed": true,
            ])
        case .rejected(_, let reason, _), .failed(_, let reason, _):
            Out.error(reason.code)
        case .accepted, .verifying:
            break
        }
    }
}

enum ServeCommand {
    static func run(_ args: Args) async -> Int32 {
        do {
            let state = try HarnessState(path: try args.required("state"))
            let approve = try Decision.parse(args)
            let dest = URL(fileURLWithPath: try args.required("dest"), isDirectory: true)
            let (host, port) = try args.hostPort("listen")
            // Optional explicit session port; by default it is ephemeral too.
            let sessionPort = try args.optional("session-port").map { raw -> UInt16 in
                guard let p = UInt16(raw) else { throw UsageError("--session-port must be a port") }
                return p
            } ?? 0
            let server = try Server(state: state, host: host, approve: approve, timeouts: HarnessTimeouts(testMode: args.flag("test-mode")), dest: dest)
            let (pairingPort, boundSession) = try await server.start(pairingPort: port, sessionPort: sessionPort)
            Out.event("listening", ["pairingPort": Int(pairingPort), "sessionPort": Int(boundSession)])
            await server.watchUnpairs()
            return 0
        } catch let usage as UsageError {
            Out.log(usage.message)
            return 64
        } catch {
            Out.error(bridgeCode(error))
            return exitCode(for: bridgeCode(error))
        }
    }
}
