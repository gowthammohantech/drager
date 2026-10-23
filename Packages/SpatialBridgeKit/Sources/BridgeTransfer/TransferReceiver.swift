import Foundation
public import BridgeCore
public import BridgeModels
import BridgeDiagnostics

/// What the receiver reports to the app (overlay, history, notifications).
public enum ReceiverEvent: Sendable {
    /// Offer passed validation and was accepted. Start the provisional animation (AD §4).
    case accepted(TransferOffer, from: TrustedPeer)
    case progress(transferID: UUID, bytesReceived: Int64, totalBytes: Int64)
    case verifying(transferID: UUID)
    /// The file is durably stored. Only now may the UI show success (FR-209).
    case committed(TransferOffer, savedURL: URL, from: TrustedPeer)
    /// Offer refused before any bytes moved.
    case rejected(TransferOffer, reason: BridgeError, from: TrustedPeer)
    /// Accepted transfer that did not complete; staging was cleaned up.
    case failed(TransferOffer, reason: BridgeError, from: TrustedPeer)
    /// A replayed offer for an ID that was already committed (ADR-011): answered
    /// with `COMMITTED` from the ledger, no bytes moved and no new file. The
    /// original `.committed` already announced success, so this must never
    /// trigger a second success notification.
    case replayed(TransferOffer, savedFilename: String, from: TrustedPeer)
}

/// Receives transfers on one authenticated session, one at a time (ADR-007).
///
/// offer → validate (trust, policy, destination, space) → ACCEPT →
/// chunks (strict sequence/offset, incremental SHA-256 into a private staging
/// file) → COMPLETE → verify size + digest → fsync → atomic collision-safe
/// commit → COMMITTED. Every failure path deletes the staging file.
public actor TransferReceiver {
    public struct Configuration: Sendable {
        public var policy: TransferPolicy
        public var progressAckInterval: Int64
        public init(policy: TransferPolicy = .default, progressAckInterval: Int64 = 1 << 20) {
            self.policy = policy
            self.progressAckInterval = progressAckInterval
        }
    }

    private let channel: SessionChannel
    private let peer: TrustedPeer
    private let localPeerID: PeerID
    private let destination: any DestinationStore
    private let staging: StagingArea
    private let ledger: TransferOutcomeLedger
    private let configuration: Configuration
    private let emit: @Sendable (ReceiverEvent) -> Void
    private let log = BridgeLogger(.transfer)

    public init(
        channel: SessionChannel,
        peer: TrustedPeer,
        localPeerID: PeerID,
        destination: any DestinationStore,
        staging: StagingArea,
        ledger: TransferOutcomeLedger,
        configuration: Configuration = Configuration(),
        emit: @escaping @Sendable (ReceiverEvent) -> Void
    ) {
        self.channel = channel
        self.peer = peer
        self.localPeerID = localPeerID
        self.destination = destination
        self.staging = staging
        self.ledger = ledger
        self.configuration = configuration
        self.emit = emit
    }

    private var limits: TransferLimits { configuration.policy.limits }

    /// Serves offers until the session closes. Never throws; errors become events.
    public func run() async {
        while true {
            let message: ControlMessage
            do {
                message = try await channel.receiveControl()
            } catch {
                return
            }
            switch message {
            case .transferOffer(let offer):
                await handle(offer)
            case .cancel, .complete, .progress:
                // Stray message for a transfer that already ended; nothing to do.
                continue
            default:
                log.error("Unexpected \(message.kind.rawValue) while idle")
                try? await channel.send(.error(TransferErrorMessage(transferID: message.transferID, code: .protocolMismatch)))
            }
        }
    }

    // MARK: Offer handling

    private func handle(_ offer: TransferOffer) async {
        // Replay / retry of a committed transfer: answer from the ledger, never
        // write again. A retry of a *failed* attempt reuses the same ID
        // (ADR-011) and is processed afresh, so one user activation can never
        // produce two saved files even if a COMMITTED message was lost.
        if case .committed(let name, let bytes) = await ledger.outcome(for: offer.transferID) {
            try? await channel.send(.committed(TransferCommitted(transferID: offer.transferID, savedFilename: name, byteCount: bytes)))
            emit(.replayed(offer, savedFilename: name, from: peer))
            return
        }

        do {
            try await validate(offer)
        } catch {
            let bridge = BridgeError.wrap(error, networkContext: false)
            log.notice("Rejected offer \(Redaction.filename(offer.filename)): \(bridge.code.rawValue)")
            await ledger.record(.failed(bridge.code), for: offer.transferID)
            try? await channel.send(.transferReject(TransferReject(transferID: offer.transferID, reason: bridge.code)))
            emit(.rejected(offer, reason: bridge, from: peer))
            return
        }

        let chunkBytes = min(limits.chunkBytes, limits.maxChunkBytes)
        do {
            try await channel.send(.transferAccept(TransferAccept(transferID: offer.transferID, chunkBytes: chunkBytes)))
        } catch {
            return
        }
        emit(.accepted(offer, from: peer))
        DiagnosticsRecorder.shared.record(analytics: AnalyticsEvent(name: .transferStarted, sizeBucket: ByteFormatting.bucket(offer.byteCount)))
        let started = ContinuousClock.now

        do {
            let savedURL = try await receive(offer)
            let committed = TransferCommitted(transferID: offer.transferID, savedFilename: savedURL.lastPathComponent, byteCount: offer.byteCount)
            await ledger.record(.committed(savedFilename: committed.savedFilename, byteCount: committed.byteCount), for: offer.transferID)
            // Emit before acknowledging so the overlay's success state and the
            // sender's success state appear together; both follow durable storage.
            emit(.committed(offer, savedURL: savedURL, from: peer))
            try? await channel.send(.committed(committed))
            let seconds = (ContinuousClock.now - started).timeInterval
            DiagnosticsRecorder.shared.record(metric: .throughputBytesPerSecond, value: seconds > 0 ? Double(offer.byteCount) / seconds : 0)
            DiagnosticsRecorder.shared.record(analytics: AnalyticsEvent(name: .transferCompleted, durationSeconds: seconds, sizeBucket: ByteFormatting.bucket(offer.byteCount)))
            log.notice("Committed \(Redaction.filename(committed.savedFilename)) (\(offer.byteCount) bytes)")
        } catch {
            let bridge = BridgeError.wrap(error, networkContext: true)
            staging.remove(offer.transferID)
            await ledger.record(.failed(bridge.code), for: offer.transferID)
            if !(await channel.isClosed) {
                try? await channel.send(.error(TransferErrorMessage(transferID: offer.transferID, code: bridge.code)))
            }
            emit(.failed(offer, reason: bridge, from: peer))
            DiagnosticsRecorder.shared.record(analytics: AnalyticsEvent(name: .transferFailed, errorCode: bridge.code))
            log.notice("Transfer \(offer.transferID.uuidString.prefix(8)) failed: \(bridge.code.rawValue)")
        }
    }

    private func validate(_ offer: TransferOffer) async throws {
        guard offer.sourcePeerID == peer.peerID else {
            throw BridgeError(.authenticationFailed, detail: "offer source does not match session peer")
        }
        guard offer.targetPeerID == localPeerID else {
            throw BridgeError(.authenticationFailed, detail: "offer addressed to another device")
        }
        try configuration.policy.validate(offer)
        try await destination.validateAccess()
        let free = try await destination.availableCapacity()
        guard free >= offer.byteCount + limits.diskHeadroomBytes else {
            throw BridgeError(.insufficientStorage, detail: "free \(free)")
        }
    }

    private func receive(_ offer: TransferOffer) async throws -> URL {
        let writer = try staging.makeWriter(for: offer.transferID, expectedBytes: offer.byteCount)
        var expectedSequence: UInt32 = 0
        var lastAck: Int64 = 0
        let firstByteTimer = MetricTimer(.firstByteLatency)
        var complete: TransferComplete?

        do {
            while complete == nil {
                let frame = try await withBridgeTimeout(limits.transferIdleTimeout) { try await self.channel.receive() }
                switch frame {
                case .chunk(let chunk):
                    guard chunk.transferID == offer.transferID else {
                        throw BridgeError(.protocolMismatch, detail: "chunk for another transfer")
                    }
                    guard chunk.sequence == expectedSequence, chunk.offset == UInt64(writer.bytesWritten) else {
                        throw BridgeError(.protocolMismatch, detail: "out-of-order chunk")
                    }
                    if expectedSequence == 0 { firstByteTimer.finish() }
                    try writer.append(chunk.payload)
                    expectedSequence &+= 1
                    if writer.bytesWritten - lastAck >= configuration.progressAckInterval || writer.bytesWritten == offer.byteCount {
                        lastAck = writer.bytesWritten
                        try await channel.send(.progress(TransferProgress(transferID: offer.transferID, acknowledgedOffset: lastAck)))
                        emit(.progress(transferID: offer.transferID, bytesReceived: lastAck, totalBytes: offer.byteCount))
                    }
                case .control(let data):
                    guard let message = try? ControlMessageCoder.decode(data) else {
                        throw BridgeError(.protocolMismatch, detail: "undecodable control")
                    }
                    switch message {
                    case .complete(let c) where c.transferID == offer.transferID:
                        complete = c
                    case .cancel(let c) where c.transferID == offer.transferID:
                        throw BridgeError(.transferCanceled, detail: "sender cancelled")
                    case .error(let e):
                        throw BridgeError(e.code, detail: "sender error")
                    case .transferOffer(let other):
                        // One transfer at a time (ADR-007).
                        try? await channel.send(.transferReject(TransferReject(transferID: other.transferID, reason: .protocolMismatch, message: "busy")))
                    default:
                        throw BridgeError(.protocolMismatch, detail: "unexpected \(message.kind.rawValue) during transfer")
                    }
                }
            }

            emit(.verifying(transferID: offer.transferID))
            let verifyTimer = MetricTimer(.verifyDuration)
            let digest = try writer.finish()
            verifyTimer.finish()
            guard let complete,
                  writer.bytesWritten == offer.byteCount,
                  complete.byteCount == offer.byteCount,
                  digest == offer.sha256Hex.lowercased(),
                  complete.sha256Hex.lowercased() == digest else {
                throw BridgeError(.hashMismatch, detail: "size or digest mismatch")
            }
            let saveTimer = MetricTimer(.saveDuration)
            let url = try await destination.commit(stagedFile: writer.url, suggestedName: offer.filename)
            saveTimer.finish()
            return url
        } catch {
            writer.abandon()
            throw error
        }
    }
}
