import BridgeCalibration
import BridgeCore
import BridgeDiagnostics
import BridgeGesture
import BridgeModels
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import CoreTransferable
import Foundation
import Observation
import PhotosUI
import QuickLookThumbnailing
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file the user picked, copied into app-owned staging (TD §7) so it stays
/// readable after the picker's access scope ends.
struct StagedItem: Identifiable, Hashable {
    enum Readiness: Hashable {
        case loading
        case ready
        case tooLarge
        case failed(String)
    }

    let id: UUID
    var url: URL?
    var filename: String
    var contentType: UTType
    var byteCount: Int64
    var readiness: Readiness
    var thumbnail: UIImage?
    var pixelSize: CGSize?

    var isReady: Bool { readiness == .ready && url != nil }
    var outgoing: OutgoingFile? {
        guard let url, isReady else { return nil }
        return OutgoingFile(url: url, filename: filename, contentType: contentType.identifier)
    }

    var kindDescription: String {
        contentType.localizedDescription ?? contentType.preferredFilenameExtension?.uppercased() ?? "File"
    }
}

/// Transferable that copies whatever file the picker hands us into staging.
nonisolated struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            PickedFile(url: try OutgoingStaging.copyIn(received.file))
        }
    }
}

/// Owned directory for outgoing files. Purged of anything older than a day at launch.
nonisolated enum OutgoingStaging {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SpatialBridge-Outgoing", isDirectory: true)
    }

    /// Copies `source` into a fresh subdirectory, keeping its filename.
    static func copyIn(_ source: URL) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func purge(olderThan age: TimeInterval = 86_400) {
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        for item in items {
            let created = (try? item.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) > age { try? FileManager.default.removeItem(at: item) }
        }
    }
}

/// Selection state for photos and files (FR-101, FR-102).
@Observable
@MainActor
final class GalleryModel {
    var items: [StagedItem] = []
    var selectedID: StagedItem.ID?
    var pickerSelection: [PhotosPickerItem] = [] {
        didSet {
            guard !pickerSelection.isEmpty else { return }
            let picked = pickerSelection
            pickerSelection = []
            importPhotos(picked)
        }
    }

    private let maxBytes: () -> Int64
    private let log = BridgeLogger(.ui)

    init(maxBytes: @escaping () -> Int64) {
        self.maxBytes = maxBytes
    }

    var selectedItem: StagedItem? {
        items.first { $0.id == selectedID }
    }

    var readyCount: Int { items.filter(\.isReady).count }

    func select(_ item: StagedItem) {
        selectedID = item.id
    }

    func remove(_ item: StagedItem) {
        if let url = item.url { OutgoingStaging.remove(url) }
        items.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = items.first(where: \.isReady)?.id }
    }

    func removeAll() {
        items.forEach { if let url = $0.url { OutgoingStaging.remove(url) } }
        items.removeAll()
        selectedID = nil
    }

    /// Imports Photos selections asynchronously into staging (bounded memory: file representations, not Data).
    func importPhotos(_ picked: [PhotosPickerItem]) {
        for pickerItem in picked {
            let id = UUID()
            let type = pickerItem.supportedContentTypes.first ?? .image
            items.append(StagedItem(id: id, url: nil, filename: "Photo", contentType: type, byteCount: 0, readiness: .loading))
            if selectedID == nil { selectedID = id }
            Task {
                do {
                    guard let file = try await pickerItem.loadTransferable(type: PickedFile.self) else {
                        throw BridgeError(.unsupportedFile, detail: "no file representation")
                    }
                    await finishImport(id: id, url: file.url, fallbackType: type)
                } catch {
                    log.error("Photo import failed: \(error.localizedDescription)")
                    update(id) { $0.readiness = .failed("Couldn't load this item. If it's stored in iCloud, check your connection and try again.") }
                }
            }
        }
    }

    /// Imports files from the Files app (security-scoped URLs).
    func importFiles(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let id = UUID()
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            items.append(StagedItem(id: id, url: nil, filename: url.lastPathComponent, contentType: type, byteCount: 0, readiness: .loading))
            if selectedID == nil { selectedID = id }
            Task {
                let copied: URL? = await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? OutgoingStaging.copyIn(url)
                }.value
                if let copied {
                    await finishImport(id: id, url: copied, fallbackType: type)
                } else {
                    update(id) { $0.readiness = .failed("Couldn't read this file.") }
                }
            }
        }
    }

    private func finishImport(id: UUID, url: URL, fallbackType: UTType) async {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let type = UTType(filenameExtension: url.pathExtension) ?? fallbackType
        update(id) { item in
            item.url = url
            item.filename = url.lastPathComponent
            item.contentType = type
            item.byteCount = size
            item.readiness = size > maxBytes() ? .tooLarge : (size == 0 ? .failed("This file is empty.") : .ready)
        }
        if let image = await Self.thumbnail(for: url) {
            update(id) { item in
                item.thumbnail = image.thumbnail
                item.pixelSize = image.pixelSize
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout StagedItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private nonisolated static func thumbnail(for url: URL) async -> (thumbnail: UIImage, pixelSize: CGSize?)? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 240), scale: 3, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        var pixelSize: CGSize?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat {
            pixelSize = CGSize(width: width, height: height)
        }
        return (representation.uiImage, pixelSize)
    }
}
