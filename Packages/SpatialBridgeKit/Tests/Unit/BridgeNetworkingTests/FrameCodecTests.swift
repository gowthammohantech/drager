import Foundation
import Testing
@testable import BridgeModels
@testable import BridgeNetworking

@Suite("Frame codec")
struct FrameCodecTests {
    @Test("Control and chunk frames round-trip")
    func roundTrip() throws {
        let control = Frame.control(Data("{\"kind\":\"PING\"}".utf8))
        let chunk = Frame.chunk(ChunkFrame(transferID: UUID(), sequence: 7, offset: 1 << 40, payload: Data(repeating: 0xAB, count: 1000)))
        var decoder = FrameDecoder()
        decoder.append(try FrameCodec.encode(control))
        decoder.append(try FrameCodec.encode(chunk))
        #expect(try decoder.next() == control)
        #expect(try decoder.next() == chunk)
        #expect(try decoder.next() == nil)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("Frames split across arbitrary byte boundaries still decode")
    func partialFeeds() throws {
        let frame = Frame.chunk(ChunkFrame(transferID: UUID(), sequence: 1, offset: 0, payload: Data((0..<300).map { UInt8($0 & 0xFF) })))
        let bytes = try FrameCodec.encode(frame)
        for split in [1, 3, 4, 5, 6, 27, 28, 29, 33, bytes.count - 1] {
            var decoder = FrameDecoder()
            decoder.append(bytes.prefix(split))
            #expect(try decoder.next() == nil, "split \(split) decoded early")
            decoder.append(bytes.dropFirst(split))
            #expect(try decoder.next() == frame, "split \(split)")
        }
    }

    @Test("Oversized lengths are rejected before allocation")
    func oversize() throws {
        let limits = TransferLimits(maxControlFrameBytes: 16, maxChunkBytes: 32)
        var header = Data([FrameCodec.controlType, 0, 0, 0, 17])
        var decoder = FrameDecoder(limits: limits)
        decoder.append(header)
        #expect(throws: FrameCodec.CodecError.lengthExceedsLimit(17)) { try decoder.next() }

        header = Data([FrameCodec.chunkType, 0, 0, 0, UInt8(ChunkFrame.headerBytes + 33)])
        var chunkDecoder = FrameDecoder(limits: limits)
        chunkDecoder.append(header)
        #expect(throws: FrameCodec.CodecError.lengthExceedsLimit(UInt32(ChunkFrame.headerBytes + 33))) { try chunkDecoder.next() }

        #expect(throws: FrameCodec.CodecError.oversizedControl(17)) {
            try FrameCodec.encode(.control(Data(count: 17)), limits: limits)
        }
    }

    @Test("Unknown frame types and malformed chunks are protocol errors")
    func malformed() throws {
        var decoder = FrameDecoder()
        decoder.append(Data([0x09, 0, 0, 0, 0]))
        #expect(throws: FrameCodec.CodecError.unknownType(0x09)) { try decoder.next() }

        var short = FrameDecoder()
        short.append(Data([FrameCodec.chunkType, 0, 0, 0, 4, 1, 2, 3, 4]))
        #expect(throws: FrameCodec.CodecError.malformedChunk) { try short.next() }
        #expect(FrameCodec.CodecError.malformedChunk.bridgeError.code == .protocolMismatch)
    }

    @Test("Header layout is 1 type byte + big-endian UInt32 length")
    func layout() throws {
        let bytes = try FrameCodec.encode(.control(Data([1, 2, 3])))
        #expect([UInt8](bytes.prefix(5)) == [0x01, 0, 0, 0, 3])
        let chunk = try FrameCodec.encode(.chunk(ChunkFrame(transferID: UUID(uuidString: "01020304-0506-0708-090A-0B0C0D0E0F10")!, sequence: 0x01020304, offset: 0x0102030405060708, payload: Data([0xFF]))))
        #expect([UInt8](chunk.prefix(5)) == [0x02, 0, 0, 0, 29])
        #expect([UInt8](chunk[5..<21]) == Array(1...16))
        #expect([UInt8](chunk[21..<25]) == [1, 2, 3, 4])
        #expect([UInt8](chunk[25..<33]) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(chunk.last == 0xFF)
    }
}
