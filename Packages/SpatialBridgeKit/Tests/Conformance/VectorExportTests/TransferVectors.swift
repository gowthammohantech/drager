import Foundation
import Testing
@testable import BridgeModels
@testable import BridgeTransfer

// MARK: - sanitizer.json

enum SanitizerVectors {
    static func corpus() -> [(String, String, String?)] {
        let jpeg = "public.jpeg"
        var c: [(String, String, String?)] = [
            // Ported from FilenameAndHashingTests.
            ("ported: parent traversal", "../../etc/passwd", nil),
            ("ported: backslash traversal", "..\\..\\win.ini", nil),
            ("ported: absolute path", "/Users/x/Desktop/photo.jpeg", nil),
            ("ported: relative path", "a/b/c.txt", nil),
            ("ported: dot dot", "..", nil),
            ("ported: dot", ".", nil),
            ("ported: empty", "", nil),
            ("ported: hidden", ".hidden", nil),
            ("ported: leading dots", "...dots.txt", nil),
            ("ported: colon", "colon:name.pdf", nil),
            ("ported: NUL byte", "nul\u{0}byte.png", nil),
            ("ported: tab", "tab\tchar.txt", nil),
            ("ported: extension from jpeg", "IMG_0001", jpeg),
            ("ported: extension from mpeg-4", "clip", "public.mpeg-4"),
            ("ported: public.data adds nothing", "Received file", "public.data"),
            ("ported: long e-acute", String(repeating: "é", count: 300) + ".jpeg", nil),
            ("ported: isSafe sanitized name", "Photo 2.jpeg", nil),
            ("ported: isSafe traversal", "../x.jpeg", nil),
            ("ported: isSafe dotfile", ".env", nil),
            // NFC.
            ("NFC: decomposed e-acute", "Cafe\u{301}.txt", nil),
            ("NFC: decomposed A-ring", "A\u{30A}ngstro\u{308}m.pdf", nil),
            ("NFC: Hangul jamo", "\u{1100}\u{1161}.txt", nil),
            ("NFC: already composed", "Café.txt", nil),
            // Separators.
            ("separator: backslashes", "a\\b\\c.txt", nil),
            ("separator: trailing slash", "photos/", nil),
            ("separator: only slash", "/", nil),
            ("separator: only backslash", "\\", nil),
            ("separator: dot dot in middle", "a/../b.txt", nil),
            ("separator: ends in dot dot", "a/b/..", nil),
            ("separator: Windows drive path", "C:\\Users\\x\\report.docx", nil),
            ("separator: mixed", "a/b\\c/d.txt", nil),
            // Leading dots and whitespace.
            ("dots: dot extension only", ".jpeg", nil),
            ("dots: dot extension with type", ".jpeg", jpeg),
            ("dots: double dot txt", "..txt", nil),
            ("dots: three dots", "...", nil),
            ("dots: space then dot", " .hidden", nil),
            ("dots: dot then space", ". name.txt", nil),
            ("dots: trailing dot", "file.", nil),
            ("dots: trailing dots", "file...", nil),
            ("dots: tar.gz", "archive.tar.gz", nil),
            ("dots: leading dot tar.gz", ".tar.gz", nil),
            // Controls and colons.
            ("control: C0 mix", "\u{1}a\u{1F}b.txt", nil),
            ("control: newline", "line\nbreak.txt", nil),
            ("control: carriage return", "cr\rname.txt", nil),
            ("control: DEL", "a\u{7F}b.txt", nil),
            ("control: C1 NEL in middle", "a\u{85}b.txt", nil),
            ("control: C1 NEL leading", "\u{85}lead.txt", nil),
            ("control: U+2028 trailing", "name.txt\u{2028}", nil),
            ("control: RTL override kept", "\u{202E}gnp.exe", nil),
            ("control: zero width space kept", "a\u{200B}b.txt", nil),
            ("colon: several", "a:b:c.txt", nil),
            ("colon: only", ":", nil),
            ("colon: in extension", "a.tx:t", nil),
            // Extension from UTI.
            ("uti: png", "IMG", "public.png"),
            ("uti: heic", "IMG", "public.heic"),
            ("uti: pdf", "doc", "com.adobe.pdf"),
            ("uti: plain text", "notes", "public.plain-text"),
            ("uti: zip", "bundle", "public.zip-archive"),
            ("uti: quicktime", "clip", "com.apple.quicktime-movie"),
            ("uti: unknown identifier", "file", "not.a.type"),
            ("uti: dyn type", "file", "dyn.ah62d4rv4ge80e5pe"),
            ("uti: empty string", "file", ""),
            ("uti: existing extension wins", "a.jpg", "public.png"),
            ("uti: empty name gets fallback and extension", "", jpeg),
            ("uti: dot name gets fallback and extension", ".", jpeg),
            // Extension cleaning and length.
            ("ext: uppercase lowered", "a.JPG", nil),
            ("ext: punctuation removed", "a.p@g", nil),
            ("ext: space removed", "a.b c", nil),
            ("ext: dash and underscore kept", "a.x-y_z", nil),
            ("ext: non-ASCII letters kept and lowered", "a.ÜNÏ", nil),
            ("ext: 16 characters kept", "a.abcdefghijklmnop", nil),
            ("ext: 17 characters truncated", "a.abcdefghijklmnopq", nil),
            ("ext: only punctuation", "a.@@", nil),
            ("ext: emoji", "a.😀", nil),
            // 255-byte truncation.
            ("truncate: 251 ASCII + .txt fits exactly", String(repeating: "a", count: 251) + ".txt", nil),
            ("truncate: 252 ASCII + .txt", String(repeating: "a", count: 252) + ".txt", nil),
            ("truncate: 300 ASCII no extension", String(repeating: "b", count: 300), nil),
            ("truncate: 4-byte emoji", String(repeating: "😀", count: 100) + ".png", nil),
            ("truncate: ZWJ family grapheme clusters", String(repeating: "👨‍👩‍👧", count: 20) + ".txt", nil),
            ("truncate: flags", String(repeating: "🇩🇪", count: 40) + ".txt", nil),
            ("truncate: decomposed e-acute (NFC first)", String(repeating: "e\u{301}", count: 200) + ".txt", nil),
            ("truncate: combining stack", String(repeating: "a\u{301}\u{302}\u{303}", count: 60) + ".txt", nil),
            ("truncate: CJK 3-byte", String(repeating: "日", count: 100) + ".txt", nil),
            ("truncate: long extension and long stem", String(repeating: "c", count: 300) + ".abcdefghijklmnopqrstuvwxyz", nil),
            // Empty or whitespace-only.
            ("empty: space", " ", nil),
            ("empty: whitespace mix", "   \t ", nil),
            ("empty: newline", "\n", nil),
            ("empty: space dot txt", " .txt", nil),
            ("whitespace: inner spaces kept", "  a  .txt", nil),
            ("whitespace: trailing space after extension", "a.txt ", nil),
            ("whitespace: no-break space", "\u{A0}a.txt\u{A0}", nil),
            // Windows-reserved names and characters (Swift leaves them alone).
            ("windows: CON.txt", "CON.txt", nil),
            ("windows: con", "con", nil),
            ("windows: NUL", "NUL", nil),
            ("windows: PRN.doc", "PRN.doc", nil),
            ("windows: AUX", "AUX", nil),
            ("windows: COM1.txt", "COM1.txt", nil),
            ("windows: LPT9", "LPT9", nil),
            ("windows: CONIN$", "CONIN$", nil),
            ("windows: angle brackets", "a<b>.txt", nil),
            ("windows: question mark", "what?.txt", nil),
            ("windows: asterisk", "star*.txt", nil),
            ("windows: pipe", "pipe|.txt", nil),
            ("windows: double quote", "quote\".txt", nil),
            ("windows: trailing dot and space", "name. ", nil),
            // Plain.
            ("plain: simple", "IMG_0001.jpeg", nil),
            ("plain: spaces", "My Photo 2.jpeg", nil),
            ("plain: unicode", "Résumé 📄.pdf", nil),
            ("plain: no extension", "README", nil),
        ]
        c.append(("plain: fallback name itself", FilenameSanitizer.fallbackBaseName, nil))
        // Found by the Kotlin/.NET fuzzers (lane H1): each once broke sanitize(sanitize(x)) == sanitize(x),
        // isSafe(sanitize(x)) or the 255-byte cap.
        c += [
            ("fuzz: junk extension after trailing ideographic space", "a*\u{3000}.@\u{FFFF}@", "com.adobe.pdf"),
            ("fuzz: junk extension after trailing space", "a .@", nil),
            ("fuzz: junk extension exposes inner extension", "a.b😀.😀", nil),
            ("fuzz: backslash with combining mark", "\\\u{338}~_<.~.-👩", nil),
            ("fuzz: slash with combining mark", "x/\u{301}y.txt", nil),
            ("fuzz: dot space dot", ". .hidden", "public.png"),
            ("fuzz: space dot space dot", " . . .x.txt", nil),
            ("fuzz: control between base and marks", "A\u{1}\u{323}\u{30A}.txt", nil),
            ("fuzz: truncation cuts the space that hid an extension", String(repeating: "x", count: 252) + ".b~ " + String(repeating: "y", count: 20), nil),
            ("fuzz: truncation leaves trailing space", String(repeating: "x", count: 254) + " y", nil),
            ("fuzz: 16 heavy graphemes in extension", "a." + String(repeating: "a" + String(repeating: "\u{301}", count: 20), count: 16), nil),
            ("fuzz: extension with ideographic space", "a.b\u{3000}c", nil),
            ("fuzz: extension with no-break space", "a.b\u{A0}c", nil),
            ("fuzz: extension with line separator", "a.b\u{2028}c", nil),
            ("fuzz: uppercase dotted I extension", "a.\u{130}\u{1E9E}", nil),
        ]
        return c
    }

    static func cases() -> [VectorCase] {
        var out: [VectorCase] = corpus().map { name, input, contentType in
            let sanitized = FilenameSanitizer.sanitize(input, contentType: contentType)
            #expect(sanitized.utf8.count <= FilenameSanitizer.maxUTF8Bytes, "\(name)")
            return [
                "name": .string(name), "op": "sanitize",
                "input": .string(input), "contentType": .optional(contentType),
                "sanitized": .string(sanitized), "sanitizedUtf8Length": .int(sanitized.utf8.count),
                "isSafe": .bool(FilenameSanitizer.isSafe(input)),
                "sanitizedIsSafe": .bool(FilenameSanitizer.isSafe(sanitized)),
            ]
        }
        let family = "👩‍👩‍👧" // one grapheme, 18 UTF-8 bytes
        let collisions: [(String, Int)] = [
            ("IMG.jpeg", 1), ("IMG.jpeg", 2), ("README", 3), ("archive.tar.gz", 2), (String(repeating: "a", count: 251) + ".txt", 12),
            // Long names: the stem is cut first so the counter always survives.
            (String(repeating: "a", count: 251) + ".txt", 2),
            (String(repeating: "a", count: 251) + ".txt", 9999),
            (String(repeating: "a", count: 255), 3),
            (String(repeating: "é", count: 125) + ".jpeg", 2),
            (String(repeating: "a", count: 16) + String(repeating: family, count: 13) + ".png", 1000),
            (String(repeating: "日", count: 80) + ".abcdefghijklmnop", 42),
            ("Résumé " + String(repeating: "x", count: 240) + ".pdf", 7),
        ]
        for (index, (name, attempt)) in collisions.enumerated() {
            let candidate = FilenameSanitizer.candidate(for: name, attempt: attempt)
            #expect(candidate.utf8.count <= FilenameSanitizer.maxUTF8Bytes)
            if attempt > 1 { #expect(candidate != name) }
            out.append([
                "name": .string(index < 5 ? "candidate: \(name.prefix(20)) attempt \(attempt)" : "candidate long \(index - 4): \(name.prefix(12)) attempt \(attempt)"), "op": "candidate",
                "input": .string(name), "attempt": .int(attempt), "candidate": .string(FilenameSanitizer.candidate(for: name, attempt: attempt)),
            ])
        }
        return out
    }
}

// MARK: - uti-policy.json

enum UTIPolicyVectors {
    static func corpus() -> [(String, String)] {
        [
            // Images, video, documents, archives.
            ("a.jpg", "public.jpeg"), ("a.jpeg", "public.jpeg"), ("a.png", "public.png"), ("a.heic", "public.heic"), ("a.gif", "com.compuserve.gif"),
            ("a.JPG", "public.jpeg"), ("a.webp", "org.webmproject.webp"),
            ("a.mov", "com.apple.quicktime-movie"), ("a.mp4", "public.mpeg-4"),
            ("a.pdf", "com.adobe.pdf"), ("a.txt", "public.plain-text"), ("a.json", "public.json"),
            ("a.docx", "org.openxmlformats.wordprocessingml.document"),
            ("a.zip", "public.zip-archive"), ("a.dmg", "com.apple.disk-image-udif"),
            // public.data with various extensions.
            ("a.jpg", "public.data"), ("a.sh", "public.data"), ("a.exe", "public.data"), ("a.app", "public.data"),
            ("a.command", "public.data"), ("a.py", "public.data"), ("a.scpt", "public.data"), ("a.bin", "public.data"),
            ("a.bat", "public.data"), ("a.ps1", "public.data"), ("a.msi", "public.data"), ("a.lnk", "public.data"),
            ("a.js", "public.data"), ("a.pkg", "public.data"), ("a.dmg", "public.data"), ("a.zip", "public.data"),
            ("a", "public.data"), ("Received file", "public.data"), ("a.SH", "public.data"),
            // Executables, bundles and scripts.
            ("a", "public.unix-executable"), ("a.app", "com.apple.application-bundle"), ("a.app", "com.apple.application"),
            ("a.exe", "com.microsoft.windows-executable"), ("a.exe", "public.executable"),
            ("a.sh", "public.shell-script"), ("a.zsh", "public.zsh-script"), ("a.py", "public.python-script"),
            ("a.rb", "public.ruby-script"), ("a.pl", "public.perl-script"),
            ("a.scpt", "com.apple.applescript.script"), ("a.applescript", "com.apple.applescript.text"),
            ("a.js", "com.netscape.javascript-source"), ("a.command", "com.apple.terminal.shell-script"),
            ("a.jpg", "public.shell-script"),
            // dyn.* and unknown identifiers.
            ("a.xyz", "dyn.ah62d4rv4ge80e5pe"), ("a.sh", "dyn.ah62d4rv4ge80e5pe"),
            ("a.xyz", "com.example.unknown"), ("a.jpg", "not.a.type"), ("a.jpg", ""),
            // Unsafe filenames fail before the type check.
            ("../a.jpg", "public.jpeg"), (".env", "public.data"),
        ]
    }

    static func cases() -> [VectorCase] {
        let peer = PeerID(rawValue: String(repeating: "a", count: 32))
        var seen = Set<String>()
        return corpus().compactMap { filename, contentType in
            let name = "\(filename) as \(contentType.isEmpty ? "(empty)" : contentType)"
            guard seen.insert(name).inserted else { return nil }
            let offer = TransferOffer(transferID: Fixtures.transferID, sourcePeerID: peer, targetPeerID: peer, filename: filename, contentType: contentType, byteCount: 1024, sha256Hex: String(repeating: "0", count: 64), gesture: nil, createdAt: Fixtures.date)
            var c: VectorCase = ["name": .string(name), "filename": .string(filename), "contentType": .string(contentType)]
            do {
                try TransferPolicy.default.validate(offer)
                c["allowedOnMac"] = true
            } catch {
                c["allowedOnMac"] = false
                c["errorCode"] = .string((error as? BridgeError)?.code.rawValue ?? "unknown")
            }
            return c
        }
    }
}
