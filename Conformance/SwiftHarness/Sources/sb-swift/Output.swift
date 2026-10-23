import Foundation
import CryptoKit
import BridgeModels

/// JSON-lines event output (CONFORMANCE.md §5). Events never carry filenames,
/// file contents, PSKs or seeds; a PSK appears only as `pskFingerprint`.
enum Out {
    private static let lock = NSLock()

    static func event(_ name: String, _ fields: [String: any Sendable] = [:]) {
        var object: [String: Any] = ["event": name]
        for (key, value) in fields { object[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        lock.withLock {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    static func error(_ code: BridgeError.Code) {
        event("error", ["code": code.rawValue])
    }

    /// Diagnostics on stderr. Callers must only pass redacted text.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("sb-swift: \(message)\n".utf8))
    }

    static func pskFingerprint(_ psk: Data) -> String {
        String(SHA256.hash(data: psk).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

/// Exit code for an error code: the numeric part (E004 -> 4).
func exitCode(for code: BridgeError.Code) -> Int32 {
    Int32(code.rawValue.dropFirst()) ?? 1
}

struct Failure: Error {
    let code: BridgeError.Code
    let detail: String
    init(_ code: BridgeError.Code, _ detail: String = "") {
        self.code = code
        self.detail = detail
    }
}

func bridgeCode(_ error: any Error) -> BridgeError.Code {
    if let f = error as? Failure { return f.code }
    if let b = error as? BridgeError { return b.code }
    return BridgeError.wrap(error, networkContext: true).code
}

extension Data {
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Self.nibble(chars[i]), let lo = Self.nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 97...102: c - 87
        case 65...70: c - 55
        default: nil
        }
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
