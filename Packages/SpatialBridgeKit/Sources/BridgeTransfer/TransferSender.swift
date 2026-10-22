import Foundation
public import BridgeCore
public import BridgeModels
import BridgeDiagnostics
import UniformTypeIdentifiers

/// A file the user chose, already copied into app-owned storage.
public struct OutgoingFile: Sendable, Hashable {
    public var url: URL
    /// Name to offer (sanitized again before sending).
    public var filename: String
    /// UTI string, e.g. `public.jpeg`.
    public var contentType: String

    public init(url: URL, filename: String? = nil, contentType: String? = nil) {
        self.url = url
        self.filename = filename ?? url.lastPathComponent
        self.contentType = contentType
            ?? UTType(filenameExtension: url.pathExtension)?.identifier
            ?? UTType.data.identifier
    }
}

/// Sends one file over an authenticated session (FR-105, FR-106, FR-108).
///
/// Preparing (hash) → offer → wait for ACCEPT/REJECT → stream bounded chunks
/// while concurrently reading PROGRESS acks → COMPLETE → wait for COMMITTED.
/// Success is reported only on COMMITTED (FR-209).
public actor TransferSender {
    public typealias ProgressHandler = @Sendable (TransferProgressSnapshot) -> Void

    private let channel: SessionChannel
    private let localPeerID: PeerID
    private let remotePeerID: PeerID
    private let limits: TransferLimits
    private let log = BridgeLogger(.transfer)
    private var busy = false

    public init(channel: SessionChannel, localPeerID: PeerID, remotePeerID: PeerID, limits: TransferLimits = .default) {
        self.channel = channel
        self.localPeerID = localPeerID
        self.remotePeerID = remotePeerID
        self.limits = limits
    }

    /// Hashes and sizes a file without loading it into memory.
    public static func prepare(_ file: OutgoingFile, limits: TransferLimits = .default) async throws -> (sha256Hex: String, byteCount: Int64) {
        let (hex, count) = try await FileHasher.sha256Hex(of: file.url)
        guard count > 0 else { throw BridgeError(.unsupportedFile, detail: "empty file") }
        guard count <= limits.maxFileBytes else { throw BridgeError(.sizeLimit, detail: "\(count) bytes") }
        return (hex, count)
    }

    /// Sends `file`. `transferID` must be fresh per user activation (FR-108);
    /// a retry uses a new ID (ADR-011). Cancel the calling task to cancel.
    public func send(
        _ file: OutgoingFile,
        transferID: UUID = UUID(),
        gesture: ExitGesture?,
        progress: @escaping ProgressHandler
    ) async throws -> TransferCommitted {
        guard !busy else { throw BridgeError(.protocolMismatch, detail: "a transfer is already in progress") }
        busy = true
        defer { busy = false }

        progress(TransferProgressSnapshot(transferID: transferID, state: .created, bytesTransferred: 0, totalBytes: 0))
        let prepared = try await Self.prepare(file, limits: limits)
        let offer = TransferOffer(
            transferID: transferID,
            sourcePeerID: localPeerID,
            targetPeerID: remotePeerID,
            filename: FilenameSanitizer.sanitize(file.filename, contentType: file.contentType),
            contentType: file.contentType,
            byteCount: prepared.byteCount,
            sha256Hex: prepared.sha256Hex,
            gesture: gesture
        )

        do {
            return try await perform(offer, file: file, progress: progress)
        } catch {
            var bridge = BridgeError.wrap(error, networkContext: true)
            if error is CancellationError || Task.isCancelled {
                bridge = BridgeError(.transferCanceled)
                // Our task is cancelled; notify the receiver from a fresh task so
                // the CANCEL frame is not itself cancelled.
                let channel = channel
                await Task { try? await channel.send(.cancel(TransferCancel(transferID: transferID))) }.value
            }
            progress(TransferProgressSnapshot(
                transferID: transferID, state: bridge.code == .transferCanceled ? .canceled : .failed,
                bytesTransferred: 0, totalBytes: prepared.byteCount, error: bridge
            ))
            throw bridge
        }
    }

    private func perform(_ offer: TransferOffer, file: OutgoingFile, progress: @escaping ProgressHandler) async throws -> TransferCommitted {
        let total = offer.byteCount
        let id = offer.transferID
        await channel.drainInbox()
        let offerTimer = MetricTimer(.offerRoundTrip)
        try await channel.send(.transferOffer(offer))
        progress(TransferProgressSnapshot(transferID: id, state: .offered, bytesTransferred: 0, totalBytes: total))

        let accept: TransferAccept
        switch try await channel.receiveControl(timeout: limits.handshakeTimeout) {
        case .transferAccept(let a) where a.transferID == id:
            accept = a
        case .transferReject(let reject) where reject.transferID == id:
            throw BridgeError(reject.reason, detail: reject.message)
        case .committed(let committed) where committed.transferID == id:
            // Receiver already committed this ID (replayed offer): never resend bytes.
            return committed
        case .error(let error):
            throw BridgeError(error.code, detail: "receiver error")
        default:
            throw BridgeError(.protocolMismatch, detail: "expected TRANSFER_ACCEPT")
        }
        offerTimer.finish()
        progress(TransferProgressSnapshot(transferID: id, state: .accepted, bytesTransferred: 0, totalBytes: total))

        let chunkBytes = max(1, min(accept.chunkBytes, limits.chunkBytes, limits.maxChunkBytes))
        let tracker = ProgressTracker(transferID: id, total: total, handler: progress)
        let channel = channel
        let idle = limits.transferIdleTimeout

        return try await withThrowingTaskGroup(of: TransferCommitted?.self) { group in
            // Writer: stream chunks, then COMPLETE.
            group.addTask {
                let reader = try ChunkedFileReader(url: file.url, chunkBytes: chunkBytes)
                defer { Task { await reader.close() } }
                var sequence: UInt32 = 0
                while let (offset, data) = try await reader.next() {
                    try Task.checkCancellation()
                    try await channel.send(.chunk(ChunkFrame(transferID: id, sequence: sequence, offset: UInt64(offset), payload: data)))
                    sequence &+= 1
                    tracker.sent(offset + Int64(data.count))
                }
                guard await reader.offset == total else {
                    throw BridgeError(.writeFailed, detail: "file changed while sending")
                }
                try await channel.send(.complete(TransferComplete(transferID: id, sha256Hex: offer.sha256Hex, byteCount: total)))
                tracker.state(.verifying)
                return nil
            }
            // Reader: acks, errors and the final COMMITTED.
            group.addTask {
                while true {
                    let message = try await channel.receiveControl(timeout: idle * 4)
                    switch message {
                    case .progress(let p) where p.transferID == id:
                        tracker.acknowledged(p.acknowledgedOffset)
                    case .committed(let c) where c.transferID == id:
                        return c
                    case .error(let e) where e.transferID == nil || e.transferID == id:
                        throw BridgeError(e.code, detail: e.message)
                    case .transferReject(let r) where r.transferID == id:
                        throw BridgeError(r.reason, detail: r.message)
                    case .cancel(let c) where c.transferID == id:
                        throw BridgeError(.transferCanceled, detail: "receiver cancelled")
                    default:
                        continue
                    }
                }
            }
            while let result = try await group.next() {
                if let committed = result {
                    group.cancelAll()
                    tracker.finish(committed)
                    return committed
                }
            }
            throw BridgeError(.peerLost, detail: "no COMMITTED")
        }
    }
}

/// Thread-safe progress aggregation for the sender. Reports the receiver's
/// acknowledged (written) offset; falls back to bytes sent until the first ack.
final class ProgressTracker: Sendable {
    private struct State {
        var sent: Int64 = 0
        var acknowledged: Int64 = 0
        var state: TransferState = .streaming
        var started = ContinuousClock.now
    }

    let transferID: UUID
    let total: Int64
    let handler: TransferSender.ProgressHandler
    private let lock = NSLock()
    nonisolated(unsafe) private var value = State()

    init(transferID: UUID, total: Int64, handler: @escaping TransferSender.ProgressHandler) {
        self.transferID = transferID
        self.total = total
        self.handler = handler
    }

    func sent(_ bytes: Int64) { update { $0.sent = bytes } }
    func acknowledged(_ bytes: Int64) { update { $0.acknowledged = max($0.acknowledged, bytes) } }
    func state(_ state: TransferState) { update { $0.state = state } }

    func finish(_ committed: TransferCommitted) {
        handler(TransferProgressSnapshot(transferID: transferID, state: .completed, bytesTransferred: total, totalBytes: total))
    }

    private func update(_ change: (inout State) -> Void) {
        let snapshot: TransferProgressSnapshot = lock.withLock {
            change(&value)
            let shown = value.acknowledged > 0 ? value.acknowledged : value.sent
            let elapsed = (ContinuousClock.now - value.started).timeInterval
            return TransferProgressSnapshot(
                transferID: transferID,
                state: value.state,
                bytesTransferred: min(shown, total),
                totalBytes: total,
                bytesPerSecond: elapsed > 0 ? Double(shown) / elapsed : 0
            )
        }
        handler(snapshot)
    }
}
