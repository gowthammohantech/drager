import Foundation
import Testing
@testable import BridgeModels
@testable import BridgeNetworking

enum FramingVectors {
    static func codecError(_ error: FrameCodec.CodecError) -> VectorCase {
        switch error {
        case .unknownType(let t): ["error": "unknownType", "errorValue": .int(Int(t))]
        case .lengthExceedsLimit(let n): ["error": "lengthExceedsLimit", "errorValue": .int(Int(n))]
        case .oversizedControl(let n): ["error": "oversizedControl", "errorValue": .int(n)]
        case .oversizedChunk(let n): ["error": "oversizedChunk", "errorValue": .int(n)]
        case .malformedChunk: ["error": "malformedChunk"]
        }
    }

    static func header(type: UInt8, length: UInt32) -> Data {
        var d = Data([type])
        withUnsafeBytes(of: length.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    static func cases() throws -> [VectorCase] {
        var out: [VectorCase] = []
        let limits = TransferLimits.default

        func roundTrip(_ frame: Frame, _ bytes: Data) throws {
            var decoder = FrameDecoder()
            decoder.append(bytes)
            #expect(try decoder.next() == frame)
            #expect(decoder.bufferedByteCount == 0)
        }

        // Small frames: full hex.
        func control(_ name: String, _ payload: Data) throws {
            let frame = Frame.control(payload)
            let bytes = try FrameCodec.encode(frame)
            try roundTrip(frame, bytes)
            out.append(["name": .string(name), "frameType": 1, "payload": .hex(payload), "payloadLength": .int(payload.count), "hex": .hex(bytes)])
        }
        func chunk(_ name: String, _ c: ChunkFrame) throws {
            let frame = Frame.chunk(c)
            let bytes = try FrameCodec.encode(frame)
            try roundTrip(frame, bytes)
            out.append([
                "name": .string(name), "frameType": 2,
                "transferID": .string(c.transferID.uuidString), "sequence": .int(Int(c.sequence)), "offset": .uint(c.offset),
                "payload": .hex(c.payload), "payloadLength": .int(c.payload.count), "hex": .hex(bytes),
            ])
        }

        try control("control empty", Data())
        try control("control 3 bytes (FrameCodecTests.layout)", Data([1, 2, 3]))
        try control("control PING message", try ControlMessageCoder.encode(.ping(Ping(sequence: 1, sentAt: Fixtures.date))))
        try chunk("chunk layout (FrameCodecTests.layout)", ChunkFrame(
            transferID: UUID(uuidString: "01020304-0506-0708-090A-0B0C0D0E0F10")!,
            sequence: 0x0102_0304, offset: 0x0102_0304_0506_0708, payload: Data([0xFF])
        ))
        try chunk("chunk empty payload", ChunkFrame(transferID: Fixtures.transferID, sequence: 0, offset: 0, payload: Data()))
        try chunk("chunk max uint fields", ChunkFrame(
            transferID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            sequence: .max, offset: .max, payload: Data([0x00, 0x7F, 0x80])
        ))

        // Large frames: header hex plus payload length and SHA-256. Payload byte i is i & 0xFF.
        func large(_ name: String, _ frame: Frame, payload: Data, headerBytes: Int, extra: VectorCase) throws {
            let bytes = try FrameCodec.encode(frame)
            try roundTrip(frame, bytes)
            var c: VectorCase = [
                "name": .string(name), "payloadPattern": "indexMod256", "payloadLength": .int(payload.count),
                "payloadSha256": .string(sha256Hex(payload)), "headerHex": .hex(bytes.prefix(headerBytes)),
                "frameLength": .int(bytes.count), "frameSha256": .string(sha256Hex(bytes)),
            ]
            c.merge(extra) { a, _ in a }
            out.append(c)
        }
        let maxControl = indexPattern(limits.maxControlFrameBytes)
        try large("control max size 65536", .control(maxControl), payload: maxControl, headerBytes: FrameCodec.headerBytes, extra: ["frameType": 1])
        for (name, size, sequence) in [("chunk 256 KiB", limits.chunkBytes, UInt32(3)), ("chunk max 512 KiB", limits.maxChunkBytes, UInt32(4))] {
            let payload = indexPattern(size)
            let c = ChunkFrame(transferID: Fixtures.transferID, sequence: sequence, offset: UInt64(sequence) * UInt64(limits.chunkBytes), payload: payload)
            try large(name, .chunk(c), payload: payload, headerBytes: FrameCodec.headerBytes + ChunkFrame.headerBytes, extra: [
                "frameType": 2, "transferID": .string(c.transferID.uuidString), "sequence": .int(Int(c.sequence)), "offset": .uint(c.offset),
            ])
        }

        // Invalid input to the decoder. `incomplete` means the decoder asks for more bytes.
        func invalidDecode(_ name: String, _ input: Data) {
            var decoder = FrameDecoder(limits: limits)
            decoder.append(input)
            var c: VectorCase = ["name": .string(name), "invalid": true, "direction": "decode", "hex": .hex(input)]
            do {
                if let frame = try decoder.next() {
                    Issue.record("\(name) decoded to \(frame)")
                    return
                }
                c["error"] = "incomplete"
            } catch let error as FrameCodec.CodecError {
                c.merge(codecError(error)) { a, _ in a }
                c["bridgeErrorCode"] = .string(error.bridgeError.code.rawValue)
            } catch {
                Issue.record("\(name): unexpected \(error)")
                return
            }
            out.append(c)
        }
        invalidDecode("unknown type 0x09", header(type: 0x09, length: 0))
        invalidDecode("unknown type 0x00", header(type: 0x00, length: 3) + Data([1, 2, 3]))
        invalidDecode("oversize control 65537", header(type: 0x01, length: UInt32(limits.maxControlFrameBytes + 1)))
        invalidDecode("oversize chunk 28+524289", header(type: 0x02, length: UInt32(ChunkFrame.headerBytes + limits.maxChunkBytes + 1)))
        invalidDecode("oversize length 0xFFFFFFFF", header(type: 0x01, length: .max))
        invalidDecode("chunk shorter than its 28-byte header", header(type: 0x02, length: 4) + Data([1, 2, 3, 4]))
        invalidDecode("truncated header (4 of 5 bytes)", Data([0x01, 0, 0, 0]))
        invalidDecode("truncated payload (2 of 3 bytes)", header(type: 0x01, length: 3) + Data([1, 2]))

        // Invalid input to the encoder.
        func invalidEncode(_ name: String, _ frame: Frame, payloadLength: Int, frameType: Int) {
            var c: VectorCase = ["name": .string(name), "invalid": true, "direction": "encode", "frameType": .int(frameType), "payloadLength": .int(payloadLength)]
            do {
                _ = try FrameCodec.encode(frame, limits: limits)
                Issue.record("\(name) encoded")
                return
            } catch let error as FrameCodec.CodecError {
                c.merge(codecError(error)) { a, _ in a }
            } catch {
                Issue.record("\(name): unexpected \(error)")
                return
            }
            out.append(c)
        }
        invalidEncode("encode control 65537 bytes", .control(Data(count: limits.maxControlFrameBytes + 1)), payloadLength: limits.maxControlFrameBytes + 1, frameType: 1)
        invalidEncode("encode chunk 524289 bytes", .chunk(ChunkFrame(transferID: Fixtures.transferID, sequence: 0, offset: 0, payload: Data(count: limits.maxChunkBytes + 1))), payloadLength: limits.maxChunkBytes + 1, frameType: 2)
        return out
    }
}
