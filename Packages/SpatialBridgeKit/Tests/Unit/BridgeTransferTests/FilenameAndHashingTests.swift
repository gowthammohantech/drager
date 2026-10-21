import CryptoKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BridgeModels
@testable import BridgeTestSupport
@testable import BridgeTransfer

@Suite("Filename sanitizer")
struct FilenameSanitizerTests {
    @Test("Path traversal and separators are neutralized", arguments: [
        ("../../etc/passwd", "passwd"),
        ("..\\..\\win.ini", "win.ini"),
        ("/Users/x/Desktop/photo.jpeg", "photo.jpeg"),
        ("a/b/c.txt", "c.txt"),
        ("..", "Received file"),
        (".", "Received file"),
        ("", "Received file"),
        (".hidden", "hidden"),
        ("...dots.txt", "dots.txt"),
        ("colon:name.pdf", "colonname.pdf"),
        ("nul\u{0}byte.png", "nulbyte.png"),
        ("tab\tchar.txt", "tabchar.txt"),
    ])
    func traversal(input: String, expected: String) {
        #expect(FilenameSanitizer.sanitize(input) == expected)
    }

    @Test("Extension is derived from the content type when missing")
    func extensionFromType() {
        #expect(FilenameSanitizer.sanitize("IMG_0001", contentType: UTType.jpeg.identifier) == "IMG_0001.jpeg")
        #expect(FilenameSanitizer.sanitize("clip", contentType: UTType.mpeg4Movie.identifier) == "clip.mp4")
        #expect(FilenameSanitizer.sanitize("Received file", contentType: "public.data") == "Received file")
    }

    @Test("Long names are truncated to 255 UTF-8 bytes preserving the extension")
    func longNames() {
        let long = String(repeating: "é", count: 300) + ".jpeg"
        let out = FilenameSanitizer.sanitize(long)
        #expect(out.utf8.count <= 255)
        #expect(out.hasSuffix(".jpeg"))
    }

    @Test("Collision candidates append a counter before the extension")
    func candidates() {
        #expect(FilenameSanitizer.candidate(for: "IMG.jpeg", attempt: 1) == "IMG.jpeg")
        #expect(FilenameSanitizer.candidate(for: "IMG.jpeg", attempt: 2) == "IMG 2.jpeg")
        #expect(FilenameSanitizer.candidate(for: "README", attempt: 3) == "README 3")
    }

    @Test("isSafe accepts sanitized names and rejects raw input")
    func isSafe() {
        #expect(FilenameSanitizer.isSafe("Photo 2.jpeg"))
        #expect(!FilenameSanitizer.isSafe("../x.jpeg"))
        #expect(!FilenameSanitizer.isSafe(".env"))
    }
}

@Suite("Transfer policy")
struct TransferPolicyTests {
    private let peer = PeerID(rawValue: String(repeating: "a", count: 32))

    private func offer(bytes: Int64 = 1024, type: String = UTType.jpeg.identifier, name: String = "a.jpeg", version: Int = BridgeProtocol.version) -> TransferOffer {
        TransferOffer(protocolVersion: version, sourcePeerID: peer, targetPeerID: peer, filename: name, contentType: type, byteCount: bytes, sha256Hex: String(repeating: "0", count: 64), gesture: nil)
    }

    @Test("Valid offers pass")
    func valid() throws {
        try TransferPolicy.default.validate(offer())
    }

    @Test("Oversize, empty, executable, unsafe and mismatched offers are rejected with the right codes")
    func rejections() {
        func code(_ o: TransferOffer) -> BridgeError.Code? {
            do { try TransferPolicy.default.validate(o); return nil } catch { return (error as? BridgeError)?.code }
        }
        #expect(code(offer(bytes: 101 * 1024 * 1024)) == .sizeLimit)
        #expect(code(offer(bytes: 0)) == .unsupportedFile)
        #expect(code(offer(type: UTType.unixExecutable.identifier, name: "a")) == .unsupportedFile)
        #expect(code(offer(type: UTType.shellScript.identifier, name: "a.sh")) == .unsupportedFile)
        #expect(code(offer(name: "../a.jpeg")) == .unsupportedFile)
        #expect(code(offer(type: "not.a.type")) == .unsupportedFile)
        #expect(code(offer(version: 99)) == .protocolMismatch)
    }

    @Test("Allow-list restricts to conforming types")
    func allowList() {
        let policy = TransferPolicy(allowedTypes: [.image])
        #expect(throws: Never.self) { try policy.validate(offer()) }
        #expect(throws: BridgeError.self) { try policy.validate(offer(type: UTType.pdf.identifier, name: "a.pdf")) }
    }
}

@Suite("Hashing")
struct HashingTests {
    @Test("Streaming hash equals one-shot CryptoKit hash")
    func streaming() {
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        var hasher = StreamingHasher()
        for chunk in stride(from: 0, to: data.count, by: 333) {
            hasher.update(data[chunk..<min(chunk + 333, data.count)])
        }
        #expect(hasher.finalizeHex() == StreamingHasher.sha256Hex(of: data))
        #expect(hasher.byteCount == Int64(data.count))
        #expect(StreamingHasher.sha256Hex(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("File hasher and chunked reader agree on a 3 MiB file")
    func fileHashing() async throws {
        let url = try RandomFileFactory.make(byteCount: 3 * 1024 * 1024 + 17)
        defer { try? FileManager.default.removeItem(at: url) }
        let (hex, count) = try await FileHasher.sha256Hex(of: url, chunkBytes: 64 * 1024)
        #expect(count == 3 * 1024 * 1024 + 17)

        let reader = try ChunkedFileReader(url: url, chunkBytes: 256 * 1024)
        var hasher = StreamingHasher()
        var expectedOffset: Int64 = 0
        while let chunk = try await reader.next() {
            #expect(chunk.offset == expectedOffset)
            expectedOffset += Int64(chunk.data.count)
            hasher.update(chunk.data)
        }
        await reader.close()
        #expect(hasher.finalizeHex() == hex)
        #expect(await reader.totalBytes == count)
    }

    @Test("Random file factory is deterministic for a seed")
    func deterministicFixtures() async throws {
        let a = try RandomFileFactory.make(byteCount: 4096, seed: 7)
        let b = try RandomFileFactory.make(byteCount: 4096, seed: 7)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        #expect(try await FileHasher.sha256Hex(of: a).hex == FileHasher.sha256Hex(of: b).hex)
    }
}
