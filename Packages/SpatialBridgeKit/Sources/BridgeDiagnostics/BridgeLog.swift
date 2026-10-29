import Foundation
public import BridgeModels
import os

/// Logging categories. One `os.Logger` per category under the shared subsystem.
public enum LogCategory: String, Sendable, CaseIterable, Codable {
    case app
    case discovery
    case pairing
    case session
    case transfer
    case storage
    case gesture
    case calibration
    case overlay
    case ui
}

public enum LogLevel: String, Sendable, Codable, Comparable {
    case debug, info, notice, error, fault

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .error: 3
        case .fault: 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// Privacy-safe structured logger. Messages are expected to be pre-scrubbed by
/// the caller; use `Redaction` helpers for filenames and peers. Every record is
/// also mirrored into `DiagnosticsRecorder` for the exportable bundle.
public struct BridgeLogger: Sendable {
    public static let subsystem = "com.gowthammohan.drager"

    public let category: LogCategory
    private let logger: Logger

    public init(_ category: LogCategory) {
        self.category = category
        self.logger = Logger(subsystem: Self.subsystem, category: category.rawValue)
    }

    public func debug(_ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("\(text, privacy: .public)")
        DiagnosticsRecorder.shared.record(category: category, level: .debug, message: text)
    }

    public func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
        DiagnosticsRecorder.shared.record(category: category, level: .info, message: text)
    }

    public func notice(_ message: @autoclosure () -> String) {
        let text = message()
        logger.notice("\(text, privacy: .public)")
        DiagnosticsRecorder.shared.record(category: category, level: .notice, message: text)
    }

    public func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
        DiagnosticsRecorder.shared.record(category: category, level: .error, message: text)
    }

    public func fault(_ message: @autoclosure () -> String) {
        let text = message()
        logger.fault("\(text, privacy: .public)")
        DiagnosticsRecorder.shared.record(category: category, level: .fault, message: text)
    }
}

/// Helpers to keep sensitive values out of logs.
public enum Redaction {
    /// `IMG_0001.jpeg` → `***.jpeg (a1b2c3)` — extension and a short stable hash only.
    public static func filename(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let hash = stableHash(name)
        return ext.isEmpty ? "*** (\(hash))" : "***.\(ext) (\(hash))"
    }

    public static func peer(_ peer: PeerID) -> String { peer.shortDescription }

    public static func path(_ url: URL) -> String {
        "…/\(filename(url.lastPathComponent))"
    }

    /// 6-hex-digit FNV-1a hash; not cryptographic, just stable for correlation.
    public static func stableHash(_ string: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%06x", hash & 0xFFFFFF)
    }
}
