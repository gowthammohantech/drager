import Darwin
import Foundation
public import BridgeCore
public import BridgeModels
import BridgeDiagnostics

/// Private staging directory for partial downloads (FR-206). Files are
/// created owner-only (0600) with a `.sbpart` extension and removed on any
/// failure; leftovers older than the retention window are purged at launch.
public struct StagingArea: Sendable {
    public static let partialExtension = "sbpart"
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// `<tmp>/SpatialBridge-Staging` inside the app container.
    public static func appDefault() throws -> StagingArea {
        try StagingArea(directory: FileManager.default.temporaryDirectory.appendingPathComponent("SpatialBridge-Staging", isDirectory: true))
    }

    public func url(for transferID: UUID) -> URL {
        directory.appendingPathComponent(transferID.uuidString).appendingPathExtension(Self.partialExtension)
    }

    public func makeWriter(for transferID: UUID, expectedBytes: Int64) throws -> StagedFileWriter {
        try StagedFileWriter(url: url(for: transferID), expectedBytes: expectedBytes)
    }

    public func remove(_ transferID: UUID) {
        try? FileManager.default.removeItem(at: url(for: transferID))
    }

    /// Deletes partial files older than `age`. Returns how many were removed.
    @discardableResult
    public func purge(olderThan age: Duration, now: Date = Date()) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var removed = 0
        for item in items where item.pathExtension == Self.partialExtension {
            let modified = (try? item.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) >= age.timeInterval {
                if (try? FileManager.default.removeItem(at: item)) != nil { removed += 1 }
            }
        }
        return removed
    }
}

/// Sequential writer for one staged file with incremental hashing.
/// Not thread-safe; owned by a single receiver actor.
public final class StagedFileWriter {
    public let url: URL
    public let expectedBytes: Int64
    public private(set) var bytesWritten: Int64 = 0
    private var hasher = StreamingHasher()
    private let handle: FileHandle
    private var isClosed = false

    init(url: URL, expectedBytes: Int64) throws {
        self.url = url
        self.expectedBytes = expectedBytes
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BridgeError(.writeFailed, detail: "cannot create staging file")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        if !isClosed { try? handle.close() }
    }

    public func append(_ data: Data) throws {
        guard bytesWritten + Int64(data.count) <= expectedBytes else {
            throw BridgeError(.protocolMismatch, detail: "more bytes than offered")
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw BridgeError.wrap(error, networkContext: false)
        }
        hasher.update(data)
        bytesWritten += Int64(data.count)
    }

    /// Flushes to stable storage and closes. Returns the SHA-256 of everything written.
    public func finish() throws -> String {
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            throw BridgeError.wrap(error, networkContext: false)
        }
        isClosed = true
        return hasher.finalizeHex()
    }

    public func abandon() {
        if !isClosed {
            try? handle.close()
            isClosed = true
        }
        try? FileManager.default.removeItem(at: url)
    }
}

/// `DestinationStore` writing into a plain folder. The macOS app wraps it with
/// security-scoped bookmark access (ADR-005); tests use it directly.
public struct FolderDestinationStore: DestinationStore {
    public let folder: URL
    public let maxCollisionAttempts: Int

    public init(folder: URL, maxCollisionAttempts: Int = 9999) {
        self.folder = folder
        self.maxCollisionAttempts = maxCollisionAttempts
    }

    public func displayPath() async -> String? {
        folder.path(percentEncoded: false)
    }

    public func validateAccess() async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BridgeError(.destinationPermissionExpired, detail: "destination missing")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw BridgeError(.destinationPermissionExpired, detail: "destination not writable")
        }
    }

    public func availableCapacity() async throws -> Int64 {
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(values.volumeAvailableCapacity ?? 0)
    }

    public func commit(stagedFile: URL, suggestedName: String) async throws -> URL {
        try Self.commit(stagedFile: stagedFile, into: folder, suggestedName: suggestedName, maxAttempts: maxCollisionAttempts)
    }

    /// Moves `stagedFile` into `folder` without ever overwriting (FR-208).
    ///
    /// Uses `renamex_np(…, RENAME_EXCL)` so the existence check and the rename
    /// are one atomic step: there is no check-then-move race. Across volumes the
    /// file is first copied to a hidden temporary inside the destination, then
    /// renamed exclusively, so a partially copied file never carries the final name.
    public static func commit(stagedFile: URL, into folder: URL, suggestedName: String, maxAttempts: Int = 9999) throws -> URL {
        let name = FilenameSanitizer.sanitize(suggestedName)
        var source = stagedFile
        var copiedTemporary: URL?
        defer { if let copiedTemporary { try? FileManager.default.removeItem(at: copiedTemporary) } }

        for attempt in 1...maxAttempts {
            let candidate = folder.appendingPathComponent(FilenameSanitizer.candidate(for: name, attempt: attempt), isDirectory: false)
            // Defence in depth: the final path must stay directly inside the folder.
            guard candidate.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else {
                throw BridgeError(.unsupportedFile, detail: "path escapes destination")
            }
            if renamex_np(source.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                copiedTemporary = nil
                return candidate
            }
            let code = errno
            switch code {
            case EEXIST:
                continue
            case EXDEV where copiedTemporary == nil:
                let temporary = folder.appendingPathComponent(".sb-incoming-\(UUID().uuidString)")
                do {
                    try FileManager.default.copyItem(at: source, to: temporary)
                } catch {
                    throw BridgeError.wrap(error, networkContext: false)
                }
                copiedTemporary = temporary
                source = temporary
                try? FileManager.default.removeItem(at: stagedFile)
                // Retry the same candidate from the same-volume temporary.
                if renamex_np(source.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                    copiedTemporary = nil
                    return candidate
                }
                if errno == EEXIST { continue }
                throw BridgeError(.writeFailed, detail: "rename errno \(errno)")
            case ENOSPC:
                throw BridgeError(.insufficientStorage, detail: "ENOSPC")
            case EACCES, EPERM:
                throw BridgeError(.destinationPermissionExpired, detail: "errno \(code)")
            default:
                throw BridgeError(.writeFailed, detail: "rename errno \(code)")
            }
        }
        throw BridgeError(.writeFailed, detail: "too many name collisions")
    }
}

/// Terminal outcomes by transfer ID so a repeated offer or COMPLETE can never
/// create a second file (AD §7). Bounded; oldest entries are evicted.
public actor TransferOutcomeLedger {
    public enum Outcome: Sendable, Hashable {
        case committed(savedFilename: String, byteCount: Int64)
        case failed(BridgeError.Code)
    }

    private var outcomes: [UUID: Outcome] = [:]
    private var order: [UUID] = []
    public let capacity: Int

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public func outcome(for id: UUID) -> Outcome? { outcomes[id] }

    public func record(_ outcome: Outcome, for id: UUID) {
        if outcomes.updateValue(outcome, forKey: id) == nil {
            order.append(id)
            if order.count > capacity {
                outcomes.removeValue(forKey: order.removeFirst())
            }
        }
    }
}
