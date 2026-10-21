import Foundation

/// Transfer state machine (FRD §1):
/// created → offered → accepted → streaming → verifying → committed → completed,
/// with failed/canceled reachable from any non-terminal state.
public enum TransferState: String, Codable, Sendable, Hashable, CaseIterable {
    case created
    case offered
    case accepted
    case streaming
    case verifying
    case committed
    case completed
    case failed
    case canceled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .canceled: true
        default: false
        }
    }

    /// Legal forward transitions. Terminal states have none.
    public func canTransition(to next: TransferState) -> Bool {
        if isTerminal { return false }
        if next == .failed || next == .canceled { return true }
        switch (self, next) {
        case (.created, .offered),
             (.offered, .accepted),
             (.accepted, .streaming),
             (.streaming, .verifying),
             (.verifying, .committed),
             (.committed, .completed):
            return true
        default:
            return false
        }
    }
}

/// Direction of a transfer from the local device's point of view.
public enum TransferDirection: String, Codable, Sendable, Hashable {
    case outgoing
    case incoming
}

/// Metadata-only description of a file being offered. Never contains file bytes.
public struct TransferOffer: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID { transferID }
    public var protocolVersion: Int
    public var transferID: UUID
    public var sourcePeerID: PeerID
    public var targetPeerID: PeerID
    /// Already-sanitized filename including extension.
    public var filename: String
    /// Uniform type identifier string (for example `public.jpeg`).
    public var contentType: String
    public var byteCount: Int64
    /// Lowercase hex SHA-256 of the whole file.
    public var sha256Hex: String
    public var gesture: ExitGesture?
    public var createdAt: Date

    public init(
        protocolVersion: Int = BridgeProtocol.version,
        transferID: UUID = UUID(),
        sourcePeerID: PeerID,
        targetPeerID: PeerID,
        filename: String,
        contentType: String,
        byteCount: Int64,
        sha256Hex: String,
        gesture: ExitGesture?,
        createdAt: Date = Date()
    ) {
        self.protocolVersion = protocolVersion
        self.transferID = transferID
        self.sourcePeerID = sourcePeerID
        self.targetPeerID = targetPeerID
        self.filename = filename
        self.contentType = contentType
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex
        self.gesture = gesture
        self.createdAt = createdAt
    }
}

/// Progress snapshot for UI.
public struct TransferProgressSnapshot: Sendable, Hashable {
    public var transferID: UUID
    public var state: TransferState
    public var bytesTransferred: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double
    public var error: BridgeError?

    public init(
        transferID: UUID,
        state: TransferState,
        bytesTransferred: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double = 0,
        error: BridgeError? = nil
    ) {
        self.transferID = transferID
        self.state = state
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.error = error
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(bytesTransferred) / Double(totalBytes))
    }
}

/// Metadata-only transfer history record. Stored locally; never includes bytes.
public struct TransferRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var direction: TransferDirection
    public var filename: String
    public var contentType: String
    public var byteCount: Int64
    public var peerID: PeerID
    public var peerDisplayName: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var state: TransferState
    public var errorCode: BridgeError.Code?
    /// Final saved location (receiver only). Path string; access still goes
    /// through the destination's security scope.
    public var savedPath: String?

    public init(
        id: UUID,
        direction: TransferDirection,
        filename: String,
        contentType: String,
        byteCount: Int64,
        peerID: PeerID,
        peerDisplayName: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        state: TransferState = .created,
        errorCode: BridgeError.Code? = nil,
        savedPath: String? = nil
    ) {
        self.id = id
        self.direction = direction
        self.filename = filename
        self.contentType = contentType
        self.byteCount = byteCount
        self.peerID = peerID
        self.peerDisplayName = peerDisplayName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.errorCode = errorCode
        self.savedPath = savedPath
    }

    public var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}
