import Foundation
public import BridgeModels

/// Binary framing for the session stream.
///
/// ```
/// +------+----------------+------------------+
/// | type | length (UInt32)|  payload (length)|
/// | 1 B  |  big-endian    |                  |
/// +------+----------------+------------------+
/// type 0x01 = control (JSON ControlMessage), payload ≤ limits.maxControlFrameBytes
/// type 0x02 = chunk: uuid(16) + sequence(UInt32 BE) + offset(UInt64 BE) + bytes, bytes ≤ limits.maxChunkBytes
/// ```
public enum FrameCodec {
    public static let headerBytes = 5
    public static let controlType: UInt8 = 0x01
    public static let chunkType: UInt8 = 0x02

    public enum CodecError: Error, Sendable, Hashable {
        case oversizedControl(Int)
        case oversizedChunk(Int)
        case unknownType(UInt8)
        case malformedChunk
        case lengthExceedsLimit(UInt32)

        public var bridgeError: BridgeError {
            BridgeError(.protocolMismatch, detail: "\(self)")
        }
    }

    public static func encode(_ frame: Frame, limits: TransferLimits = .default) throws -> Data {
        switch frame {
        case .control(let payload):
            guard payload.count <= limits.maxControlFrameBytes else { throw CodecError.oversizedControl(payload.count) }
            var out = Data(capacity: headerBytes + payload.count)
            out.append(controlType)
            out.append(bigEndian: UInt32(payload.count))
            out.append(payload)
            return out
        case .chunk(let chunk):
            guard chunk.payload.count <= limits.maxChunkBytes else { throw CodecError.oversizedChunk(chunk.payload.count) }
            let length = ChunkFrame.headerBytes + chunk.payload.count
            var out = Data(capacity: headerBytes + length)
            out.append(chunkType)
            out.append(bigEndian: UInt32(length))
            out.append(contentsOf: uuidBytes(chunk.transferID))
            out.append(bigEndian: chunk.sequence)
            out.append(bigEndian: chunk.offset)
            out.append(chunk.payload)
            return out
        }
    }

    /// Maximum payload length allowed for a given type; used to reject before allocating.
    public static func maximumPayloadLength(forType type: UInt8, limits: TransferLimits) -> Int? {
        switch type {
        case controlType: limits.maxControlFrameBytes
        case chunkType: ChunkFrame.headerBytes + limits.maxChunkBytes
        default: nil
        }
    }

    /// Parses a header. Returns `nil` if fewer than 5 bytes are available.
    public static func parseHeader(_ data: Data, limits: TransferLimits) throws -> (type: UInt8, length: Int)? {
        guard data.count >= headerBytes else { return nil }
        let type = data[data.startIndex]
        let length = data.readUInt32BE(at: data.startIndex + 1)
        guard let max = maximumPayloadLength(forType: type, limits: limits) else { throw CodecError.unknownType(type) }
        guard Int(length) <= max else { throw CodecError.lengthExceedsLimit(length) }
        return (type, Int(length))
    }

    public static func decodePayload(type: UInt8, payload: Data) throws -> Frame {
        switch type {
        case controlType:
            return .control(payload)
        case chunkType:
            guard payload.count >= ChunkFrame.headerBytes else { throw CodecError.malformedChunk }
            let start = payload.startIndex
            let uuid = uuidFrom(payload[start..<start + 16])
            let sequence = payload.readUInt32BE(at: start + 16)
            let offset = payload.readUInt64BE(at: start + 20)
            let bytes = Data(payload[(start + ChunkFrame.headerBytes)...])
            return .chunk(ChunkFrame(transferID: uuid, sequence: sequence, offset: offset, payload: bytes))
        default:
            throw CodecError.unknownType(type)
        }
    }

    static func uuidBytes(_ uuid: UUID) -> [UInt8] {
        let u = uuid.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    static func uuidFrom(_ slice: Data) -> UUID {
        precondition(slice.count == 16)
        let b = [UInt8](slice)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// Incremental decoder for a byte stream. Feed bytes with `append`, pull frames with `next`.
public struct FrameDecoder: Sendable {
    public var limits: TransferLimits
    private var buffer = Data()

    public init(limits: TransferLimits = .default) {
        self.limits = limits
    }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Bytes currently buffered (for tests and backpressure decisions).
    public var bufferedByteCount: Int { buffer.count }

    /// Returns the next complete frame, or `nil` if more bytes are needed.
    /// Throws `FrameCodec.CodecError` on protocol violations; the caller must close the connection.
    public mutating func next() throws -> Frame? {
        guard let header = try FrameCodec.parseHeader(buffer, limits: limits) else { return nil }
        let total = FrameCodec.headerBytes + header.length
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: (buffer.startIndex + FrameCodec.headerBytes)..<(buffer.startIndex + total))
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + total))
        return try FrameCodec.decodePayload(type: header.type, payload: payload)
    }
}

// MARK: - Data helpers

extension Data {
    mutating func append(bigEndian value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    mutating func append(bigEndian value: UInt64) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    func readUInt32BE(at index: Index) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value = (value << 8) | UInt32(self[index + i])
        }
        return value
    }

    func readUInt64BE(at index: Index) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(self[index + i])
        }
        return value
    }
}
