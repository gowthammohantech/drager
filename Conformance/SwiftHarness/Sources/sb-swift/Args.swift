import Foundation

/// Hand-rolled `--key value` / `--flag` parser (no remote dependencies).
struct Args {
    let command: String
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    static let booleanFlags: Set<String> = ["test-mode"]

    init(_ argv: [String]) throws {
        guard let first = argv.first else { throw UsageError("missing command") }
        command = first
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            guard arg.hasPrefix("--") else { throw UsageError("unexpected argument") }
            let name = String(arg.dropFirst(2))
            if Self.booleanFlags.contains(name) {
                flags.insert(name)
                i += 1
                continue
            }
            guard i + 1 < argv.count else { throw UsageError("missing value for --\(name)") }
            values[name] = argv[i + 1]
            i += 2
        }
    }

    func optional(_ name: String) -> String? { values[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) }

    func required(_ name: String) throws -> String {
        guard let v = values[name] else { throw UsageError("missing --\(name)") }
        return v
    }

    func hostPort(_ name: String) throws -> (host: String, port: UInt16) {
        let raw = try required(name)
        guard let colon = raw.lastIndex(of: ":"), let port = UInt16(raw[raw.index(after: colon)...]) else {
            throw UsageError("--\(name) must be HOST:PORT")
        }
        var host = String(raw[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host, port)
    }
}

struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
