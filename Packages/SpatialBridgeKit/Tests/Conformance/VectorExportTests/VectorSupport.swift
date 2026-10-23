import CryptoKit
import Foundation
import Testing
@testable import BridgeSecurity

// MARK: - JSON value

/// Minimal JSON tree for vector files. Encoded with sorted keys, so output is deterministic.
indirect enum JV: Encodable {
    case string(String)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case bool(Bool)
    case array([JV])
    case object([String: JV])
    case null

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .uint(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    static func hex(_ data: Data) -> JV { .string(hexString(data)) }
    static func hex(_ bytes: [UInt8]) -> JV { .string(hexString(Data(bytes))) }
    static func int(_ v: Int) -> JV { .int(Int64(v)) }
    static func optional(_ v: String?) -> JV { v.map(JV.string) ?? .null }
}

extension JV: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int64) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(arrayLiteral elements: JV...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JV)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

typealias VectorCase = [String: JV]

// MARK: - Bytes

func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func unhex(_ string: String) -> Data {
    precondition(string.count.isMultiple(of: 2))
    var out = Data(capacity: string.count / 2)
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        out.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return out
}

func sha256Hex(_ data: Data) -> String {
    hexString(Data(SHA256.hash(data: data)))
}

/// `count` bytes where byte `i` is `i & 0xFF`.
func indexPattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
}

/// `count` bytes `start, start+1, …` (wrapping). Used for fixed keys, nonces and challenges.
func counting(from start: UInt8, count: Int = 32) -> Data {
    Data((0..<count).map { start &+ UInt8(truncatingIfNeeded: $0) })
}

// MARK: - Signature book

/// CryptoKit Ed25519 signatures are randomized, so a freshly generated file
/// would differ every run. Before signing, the book looks for a signature for
/// the same public key and message in the file already on disk and reuses it
/// when it still verifies. Signature vectors are therefore verify-only, but
/// regenerating gives no diff.
final class SignatureBook {
    private var known: [String: [Data]] = [:]

    init(existingFile: Data?) {
        guard let existingFile, let root = try? JSONSerialization.jsonObject(with: existingFile) else { return }
        collect(root)
    }

    private func collect(_ node: Any) {
        if let dict = node as? [String: Any] {
            if let pk = dict["publicKey"] as? String, let msg = dict["message"] as? String, let sig = dict["signature"] as? String,
               pk.count.isMultiple(of: 2), msg.count.isMultiple(of: 2), sig.count.isMultiple(of: 2),
               pk.allSatisfy(\.isHexDigit), msg.allSatisfy(\.isHexDigit), sig.allSatisfy(\.isHexDigit) {
                known[pk + "|" + msg, default: []].append(unhex(sig))
            }
            for value in dict.values { collect(value) }
        } else if let array = node as? [Any] {
            for value in array { collect(value) }
        }
    }

    /// A signature by `identity` over `message`, reused from disk when possible.
    func signature(_ identity: DeviceIdentity, over message: Data) throws -> Data {
        let key = hexString(identity.publicKeyData) + "|" + hexString(message)
        if let reused = known[key]?.first(where: {
            DeviceIdentity.verify(signature: $0, over: message, publicKey: identity.publicKeyData)
        }) {
            return reused
        }
        let fresh = try identity.sign(message)
        known[key, default: []].insert(fresh, at: 0)
        return fresh
    }

    /// `{publicKey, message, signature, verifyOnly: true}`.
    func signatureObject(_ identity: DeviceIdentity, over message: Data) throws -> JV {
        let signature = try signature(identity, over: message)
        #expect(DeviceIdentity.verify(signature: signature, over: message, publicKey: identity.publicKeyData))
        return [
            "publicKey": .hex(identity.publicKeyData),
            "message": .hex(message),
            "signature": .hex(signature),
            "verifyOnly": true,
        ]
    }
}

// MARK: - Export / check

enum VectorFile {
    static let kinds: Set<String> = [
        "framing", "control-messages", "canonical-json", "pairing", "session-auth",
        "ed25519", "sanitizer", "uti-policy", "coordinate-mapper",
    ]

    /// `<repo>/Packages/SpatialBridgeKit/Tests/Conformance/VectorExportTests/VectorSupport.swift` → `<repo>`.
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    static let directory = repoRoot.appendingPathComponent("Conformance/vectors", isDirectory: true)

    static var writeMode: Bool { ProcessInfo.processInfo.environment["SB_WRITE_VECTORS"] == "1" }

    static func url(for kind: String) -> URL { directory.appendingPathComponent("\(kind).json") }

    /// Generates `<kind>.json`. In write mode it writes the file; otherwise it
    /// fails if the file on disk differs from what the generator produces.
    static func export(_ kind: String, _ generate: (SignatureBook) throws -> [VectorCase]) throws {
        precondition(kinds.contains(kind), "unknown vector kind \(kind)")
        let url = url(for: kind)
        let existing = try? Data(contentsOf: url)
        let book = SignatureBook(existingFile: existing)
        let cases = try generate(book)

        #expect(!cases.isEmpty, "\(kind): no cases")
        var names = Set<String>()
        for item in cases {
            guard case .string(let name)? = item["name"], !name.isEmpty else {
                Issue.record("\(kind): case without a name")
                continue
            }
            #expect(names.insert(name).inserted, "\(kind): duplicate case name \(name)")
        }

        let file: JV = ["version": 1, "kind": .string(kind), "cases": .array(cases.map(JV.object))]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(file)
        data.append(0x0A)

        if writeMode {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if existing != data { try data.write(to: url, options: .atomic) }
        } else if existing != data {
            Issue.record("""
                Conformance/vectors/\(kind).json is \(existing == nil ? "missing" : "out of date"). \
                Regenerate with: SB_WRITE_VECTORS=1 swift test --package-path Packages/SpatialBridgeKit --filter VectorExport
                """)
        }
    }
}
