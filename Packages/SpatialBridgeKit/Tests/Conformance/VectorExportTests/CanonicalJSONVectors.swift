import Foundation
import Testing
@testable import BridgeModels
@testable import BridgeNetworking

/// Strings, base64, dates and UUIDs encoded through `ControlMessageCoder`.
/// The value literal is cut out of a real message by its known byte prefix and suffix.
enum CanonicalJSONVectors {
    static func literal(of data: Data, prefix: String, suffix: String) -> String? {
        let bytes = [UInt8](data)
        let p = [UInt8](prefix.utf8), s = [UInt8](suffix.utf8)
        guard bytes.count >= p.count + s.count, Array(bytes.prefix(p.count)) == p, Array(bytes.suffix(s.count)) == s else { return nil }
        return String(decoding: bytes[p.count..<(bytes.count - s.count)], as: UTF8.self)
    }

    static func stringCorpus() -> [(String, String)] {
        var corpus: [(String, String)] = [
            ("empty", ""),
            ("plain ASCII", "hello"),
            ("quote", "a\"b"),
            ("backslash", "a\\b"),
            ("slash is not escaped", "a/b"),
            ("quote backslash slash", "\"\\/"),
        ]
        for value in 0x00...0x1F {
            corpus.append((String(format: "C0 control U+%04X", value), "x" + String(Character(Unicode.Scalar(UInt8(value)))) + "y"))
        }
        corpus += [
            ("DEL U+007F", "x\u{7F}y"),
            ("C1 control NEL U+0085", "x\u{85}y"),
            ("U+2028 line separator", "x\u{2028}y"),
            ("U+2029 paragraph separator", "x\u{2029}y"),
            ("BOM U+FEFF", "\u{FEFF}x"),
            ("replacement char U+FFFD", "\u{FFFD}"),
            ("noncharacter U+FFFF", "x\u{FFFF}y"),
            ("non-BMP emoji", "😀"),
            ("ZWJ family sequence", "👨‍👩‍👧"),
            ("flag", "🇩🇪"),
            ("skin tone modifier", "👍🏽"),
            ("combining mark (not normalized)", "e\u{301}"),
            ("precomposed e-acute", "é"),
            ("combining mark at start", "\u{301}x"),
            ("Hebrew RTL", "שלום"),
            ("Arabic RTL", "مرحبا"),
            ("RTL override", "abc\u{202E}gnp.exe"),
            ("CJK", "日本語のファイル"),
            ("NUL inside text", "ab\u{0}cd"),
            ("mixed escapes", "tab\tnew\nline\r\"q\"\\/"),
            ("long mixed 1024 code points", String(repeating: "Ab😀é\"\\/\n", count: 128)),
        ]
        return corpus
    }

    static func cases() throws -> [VectorCase] {
        var out: [VectorCase] = []

        // Strings: ERROR.message (no length cap, unlike HELLO displayName which keeps 64 grapheme clusters).
        let prefix = #"{"body":{"code":"E012","message":"#, suffix = #"},"kind":"ERROR"}"#
        for (name, value) in stringCorpus() {
            let data = try ControlMessageCoder.encode(.error(TransferErrorMessage(transferID: nil, code: .protocolMismatch, message: value)))
            guard let lit = literal(of: data, prefix: prefix, suffix: suffix) else {
                Issue.record("string \(name): unexpected envelope")
                continue
            }
            // Must decode back to the exact scalars (no normalization).
            if case .error(let decoded) = try ControlMessageCoder.decode(data) {
                #expect(decoded.message.map { Array($0.unicodeScalars) } == Array(value.unicodeScalars), "\(name)")
            }
            out.append([
                "name": .string("string: \(name)"), "type": "string", "field": "ERROR.body.message",
                "input": .array(value.unicodeScalars.map { .int(Int($0.value)) }),
                "inputUtf8": .hex(Data(value.utf8)),
                "json": .string(lit),
            ])
        }

        // Data → base64: SESSION_AUTH.signature.
        for (name, bytes) in [("0 bytes", Data()), ("1 byte", Data([0xFF])), ("2 bytes", Data([0xFB, 0xEF])), ("3 bytes", Data([0x00, 0x01, 0x02])),
                              ("4 bytes", Data([0xFF, 0xFE, 0xFD, 0xFC])), ("5 bytes", Data([0x3E, 0x3F, 0xF8, 0xFC, 0x00])), ("32 bytes", indexPattern(32)),
                              ("64 bytes with +/ ", Data(repeating: 0xFB, count: 64))] {
            let data = try ControlMessageCoder.encode(.sessionAuth(SessionAuth(signature: bytes)))
            guard let lit = literal(of: data, prefix: #"{"body":{"signature":"#, suffix: #"},"kind":"SESSION_AUTH"}"#) else {
                Issue.record("base64 \(name)"); continue
            }
            out.append(["name": .string("base64: \(name)"), "type": "base64", "field": "SESSION_AUTH.body.signature", "inputHex": .hex(bytes), "json": .string(lit)])
        }

        // Date → integer milliseconds: PING.sentAt. Swift's Date stores seconds since 2001, so
        // `secondsSince1970` is the input Swift was given; `milliseconds` is the value on the wire.
        for seconds in [0.0, 1.0, 0.0004, 0.0005, 0.0006, 1.0005, -1.5, -0.0005, 1_760_000_000.123, 1_760_000_000.1234,
                        1_760_000_000.1235, 1_760_000_000.9999, 978_307_200.0, 253_402_300_799.999] {
            let data = try ControlMessageCoder.encode(.ping(Ping(sequence: 0, sentAt: Date(timeIntervalSince1970: seconds))))
            guard let lit = literal(of: data, prefix: #"{"body":{"sentAt":"#, suffix: #","sequence":0},"kind":"PING"}"#), let ms = Int64(lit) else {
                Issue.record("date \(seconds)"); continue
            }
            out.append(["name": .string("date-ms: \(seconds)"), "type": "date-ms", "field": "PING.body.sentAt",
                        "secondsSince1970": .double(seconds), "milliseconds": .int(ms), "json": .string(lit),
                        // false where Date's 2001-based storage shifts a .5 ms tie; ports that hold
                        // integer milliseconds should test decoding against `milliseconds` only.
                        "matchesNaiveRounding": .bool(ms == Int64((seconds * 1000).rounded()))])
        }

        // UUIDs: CANCEL.transferID, plus RFC 4122 bytes as used in chunk frames.
        for (name, input) in [("uppercase", "3F2504E0-4F89-41D3-9A0C-0305E82C3301"), ("lowercase input", "3f2504e0-4f89-41d3-9a0c-0305e82c3301"),
                              ("nil UUID", "00000000-0000-0000-0000-000000000000"), ("max UUID", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"),
                              ("byte order", "01020304-0506-0708-090A-0B0C0D0E0F10")] {
            let uuid = UUID(uuidString: input)!
            let data = try ControlMessageCoder.encode(.cancel(TransferCancel(transferID: uuid)))
            guard let lit = literal(of: data, prefix: #"{"body":{"reason":"E013","transferID":"#, suffix: #"},"kind":"CANCEL"}"#) else {
                Issue.record("uuid \(name)"); continue
            }
            // Lowercase is accepted on input.
            let lower = String(decoding: data, as: UTF8.self).replacingOccurrences(of: uuid.uuidString, with: uuid.uuidString.lowercased())
            #expect(try ControlMessageCoder.decode(Data(lower.utf8)) == .cancel(TransferCancel(transferID: uuid)))
            out.append(["name": .string("uuid: \(name)"), "type": "uuid", "field": "CANCEL.body.transferID", "input": .string(input),
                        "bytesHex": .hex(FrameCodec.uuidBytes(uuid)), "json": .string(lit)])
        }
        return out
    }
}
