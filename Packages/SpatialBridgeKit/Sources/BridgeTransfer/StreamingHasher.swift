import CryptoKit
import Foundation
public import BridgeModels

/// Incremental SHA-256 for chunked streams.
public struct StreamingHasher: Sendable {
    private var hasher = SHA256()
    public private(set) var byteCount: Int64 = 0

    public init() {}

    public mutating func update(_ data: Data) {
        hasher.update(data: data)
        byteCount += Int64(data.count)
    }

    public func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One-shot helper.
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Hashes files without loading them into memory.
public enum FileHasher {
    /// Streams the file in `chunkBytes` pieces off the calling actor.
    public static func sha256Hex(of url: URL, chunkBytes: Int = 1 << 20) async throws -> (hex: String, byteCount: Int64) {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = StreamingHasher()
            while true {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: chunkBytes), !data.isEmpty else { break }
                hasher.update(data)
            }
            return (hasher.finalizeHex(), hasher.byteCount)
        }.value
    }
}

/// Reads a file as a sequence of chunks for streaming. Confined to an actor so
/// the non-Sendable `FileHandle` never crosses isolation boundaries.
public actor ChunkedFileReader {
    private let handle: FileHandle
    public let chunkBytes: Int
    public private(set) var offset: Int64 = 0
    public let totalBytes: Int64

    public init(url: URL, chunkBytes: Int) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.chunkBytes = chunkBytes
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        totalBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Next chunk, or `nil` at end of file.
    public func next() throws -> (offset: Int64, data: Data)? {
        guard let data = try handle.read(upToCount: chunkBytes), !data.isEmpty else { return nil }
        let start = offset
        offset += Int64(data.count)
        return (start, data)
    }

    public func seek(to newOffset: Int64) throws {
        try handle.seek(toOffset: UInt64(newOffset))
        offset = newOffset
    }

    public func close() {
        try? handle.close()
    }
}
