import Foundation

/// Data-plane unit carried on the session stream. Control frames carry an
/// encoded `ControlMessage`; chunk frames carry raw file bytes. Binary layout is
/// defined by `BridgeNetworking.FrameCodec`; this type is the decoded form.
public enum Frame: Sendable, Hashable {
    case control(Data)
    case chunk(ChunkFrame)

    public var isChunk: Bool {
        if case .chunk = self { return true }
        return false
    }
}

/// A slice of a file in flight. Offsets are monotonically increasing and
/// sequences are contiguous within a transfer.
public struct ChunkFrame: Sendable, Hashable {
    public var transferID: UUID
    public var sequence: UInt32
    public var offset: UInt64
    public var payload: Data

    public init(transferID: UUID, sequence: UInt32, offset: UInt64, payload: Data) {
        self.transferID = transferID
        self.sequence = sequence
        self.offset = offset
        self.payload = payload
    }

    /// Fixed header bytes preceding the payload: 16 (uuid) + 4 (sequence) + 8 (offset).
    public static let headerBytes = 28
}
