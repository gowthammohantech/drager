import Foundation
public import BridgeModels
import UniformTypeIdentifiers

/// Produces safe filenames from untrusted input (AD §6 boundary 4).
public enum FilenameSanitizer {
    public static let maxUTF8Bytes = 255
    public static let fallbackBaseName = "Received file"

    /// Sanitizes `name`:
    /// - strips directory components, path separators, colons, NUL and control characters
    /// - rejects `.`/`..` and leading dots (hidden files)
    /// - NFC-normalizes and caps at 255 UTF-8 bytes while preserving the extension
    /// - adds an extension from `contentType` if the name has none
    public static func sanitize(_ name: String, contentType: String? = nil) -> String {
        // Only the last path component counts; anything that looks like a path is hostile.
        var base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        base = base.precomposedStringWithCanonicalMapping
        base = String(base.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 || scalar.value == 0x7F) && scalar != ":" && scalar != "\u{0}"
        })
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." {
            base = fallbackBaseName
        }

        var stem = (base as NSString).deletingPathExtension
        var ext = (base as NSString).pathExtension
        if stem.isEmpty {
            stem = fallbackBaseName
        }
        if ext.isEmpty, let contentType, let preferred = UTType(contentType)?.preferredFilenameExtension {
            ext = preferred
        }
        // Extensions are restricted to a conservative charset.
        ext = String(ext.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }).lowercased()
        if ext.count > 16 { ext = String(ext.prefix(16)) }

        return truncate(stem: stem, ext: ext)
    }

    /// `IMG.jpeg`, attempt 2 → `IMG 2.jpeg`.
    ///
    /// The stem is shortened first (by whole grapheme clusters) so that `stem N.ext` fits in
    /// 255 UTF-8 bytes and the ` N` counter is always kept. Cutting the joined `stem N` instead
    /// would drop the counter for long names and yield the same candidate on every attempt.
    public static func candidate(for name: String, attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let counter = " \(attempt)"
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let budget = maxUTF8Bytes - suffix.utf8.count - counter.utf8.count
        var trimmed = stem
        while trimmed.utf8.count > budget, !trimmed.isEmpty {
            trimmed.removeLast()
        }
        if trimmed.isEmpty { trimmed = fallbackBaseName }
        // Only pathological extensions leave no room; the final cap keeps the 255-byte limit.
        return truncate(stem: trimmed + counter, ext: ext)
    }

    private static func truncate(stem: String, ext: String) -> String {
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let budget = maxUTF8Bytes - suffix.utf8.count
        var trimmed = stem
        while trimmed.utf8.count > budget, !trimmed.isEmpty {
            trimmed.removeLast()
        }
        if trimmed.isEmpty { trimmed = fallbackBaseName }
        return trimmed + suffix
    }

    /// `true` if `name` is exactly what `sanitize` would produce — used to validate incoming offers.
    public static func isSafe(_ name: String) -> Bool {
        sanitize(name) == name && !name.contains("/") && !name.contains("\\")
    }
}

/// Accept/reject policy for incoming offers (FR-203).
public struct TransferPolicy: Sendable {
    public var limits: TransferLimits
    /// Types that are never accepted, even if the user asks. Gatekeeper
    /// quarantine still applies to everything that is accepted.
    public var deniedTypes: [UTType]
    /// If non-empty, only these types (or their subtypes) are accepted.
    public var allowedTypes: [UTType]

    public init(
        limits: TransferLimits = .default,
        deniedTypes: [UTType] = TransferPolicy.defaultDeniedTypes,
        allowedTypes: [UTType] = []
    ) {
        self.limits = limits
        self.deniedTypes = deniedTypes
        self.allowedTypes = allowedTypes
    }

    public static let defaultDeniedTypes: [UTType] = [
        .application, .unixExecutable, .shellScript, .appleScript, .osaScript,
    ]

    public static let `default` = TransferPolicy()

    /// Validates an offer's metadata. Throws a `BridgeError` with the rejection reason.
    public func validate(_ offer: TransferOffer) throws {
        guard offer.protocolVersion == BridgeProtocol.version else {
            throw BridgeError(.protocolMismatch, detail: "offer v\(offer.protocolVersion)")
        }
        guard offer.byteCount > 0 else {
            throw BridgeError(.unsupportedFile, detail: "empty file")
        }
        guard offer.byteCount <= limits.maxFileBytes else {
            throw BridgeError(.sizeLimit, detail: "\(offer.byteCount) > \(limits.maxFileBytes)")
        }
        guard offer.sha256Hex.count == 64, offer.sha256Hex.allSatisfy({ $0.isHexDigit }) else {
            throw BridgeError(.protocolMismatch, detail: "bad digest")
        }
        guard FilenameSanitizer.isSafe(offer.filename) else {
            throw BridgeError(.unsupportedFile, detail: "unsafe filename")
        }
        guard let type = UTType(offer.contentType) else {
            throw BridgeError(.unsupportedFile, detail: "unknown type")
        }
        if deniedTypes.contains(where: { type.conforms(to: $0) }) {
            throw BridgeError(.unsupportedFile, detail: "denied type")
        }
        // Don't trust the sender's label alone (ADR-015): `x.sh` offered as
        // `public.data` is still a script once saved.
        if let byExtension = Self.typeForExtension(of: offer.filename), deniedTypes.contains(where: { byExtension.conforms(to: $0) }) {
            throw BridgeError(.unsupportedFile, detail: "denied extension")
        }
        if !allowedTypes.isEmpty, !allowedTypes.contains(where: { type.conforms(to: $0) }) {
            throw BridgeError(.unsupportedFile, detail: "type not allowed")
        }
    }

    /// The type the system infers from `filename`'s extension, if it has one.
    static func typeForExtension(of filename: String) -> UTType? {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)
    }
}
