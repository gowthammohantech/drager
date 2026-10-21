import AppKit
import BridgeCalibration
import BridgeCore
import BridgeDiagnostics
import BridgeModels
import BridgeNetworking
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import Foundation
import UniformTypeIdentifiers
import os

/// User-chosen destination folder persisted as an app-scoped security-scoped
/// bookmark (ADR-005, FR-207). Every operation brackets access with
/// `startAccessingSecurityScopedResource` / `stop…`. A stale or unresolvable
/// bookmark surfaces as E009 so the UI can ask for the folder again (T-08).
final class BookmarkedFolderStore: DestinationStore, @unchecked Sendable {
    static let defaultsKey = "spatialbridge.destination.bookmark"

    private let defaults: UserDefaults
    private let state = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private let log = BridgeLogger(.storage)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasBookmark: Bool { defaults.data(forKey: Self.defaultsKey) != nil }

    /// Saves a bookmark for a folder the user picked in `NSOpenPanel`.
    func setFolder(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: Self.defaultsKey)
        state.withLock { $0 = url }
        log.notice("Destination folder set")
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
        state.withLock { $0 = nil }
    }

    /// Resolves the bookmark, refreshing it if the system marks it stale.
    func resolve() throws -> URL {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            throw BridgeError(.destinationPermissionExpired, detail: "no destination chosen")
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw BridgeError(.destinationPermissionExpired, detail: "bookmark unresolvable")
        }
        if stale {
            // Renew while we still have access; if that fails, the user must pick again.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard scoped, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
                throw BridgeError(.destinationPermissionExpired, detail: "bookmark stale")
            }
            defaults.set(fresh, forKey: Self.defaultsKey)
        }
        state.withLock { $0 = url }
        return url
    }

    /// Runs `body` with security-scoped access to the folder.
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let url = try resolve()
        guard url.startAccessingSecurityScopedResource() else {
            throw BridgeError(.destinationPermissionExpired, detail: "access denied")
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url)
    }

    // MARK: DestinationStore

    func displayPath() async -> String? {
        (state.withLock { $0 } ?? (try? resolve()))?.path(percentEncoded: false)
    }

    func validateAccess() async throws {
        try withAccess { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isWritableFile(atPath: url.path) else {
                throw BridgeError(.destinationPermissionExpired, detail: "folder missing or read-only")
            }
        }
    }

    func availableCapacity() async throws -> Int64 {
        try withAccess { url in
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
            return Int64(values.volumeAvailableCapacity ?? 0)
        }
    }

    func commit(stagedFile: URL, suggestedName: String) async throws -> URL {
        try withAccess { folder in
            try FolderDestinationStore.commit(stagedFile: stagedFile, into: folder, suggestedName: suggestedName)
        }
    }

    /// Reveals a saved file in Finder (inside the security scope).
    @MainActor
    func reveal(path: String) {
        do {
            try withAccess { _ in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        } catch {
            log.error("Reveal failed: \(BridgeError.wrap(error, networkContext: false).code.rawValue)")
        }
    }
}
