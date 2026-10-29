import Foundation

/// Atomic JSON file persistence for small collections.
public actor JSONFileStore<Value: Codable & Sendable> {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cache: Value?

    public init(url: URL) {
        self.url = url
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Default location inside Application Support/<bundle>/<name>.json.
    public static func applicationSupportURL(fileName: String, fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.gowthammohan.drager"
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    public func load(default defaultValue: @autoclosure () -> Value) -> Value {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: url), let decoded = try? decoder.decode(Value.self, from: data) else {
            let value = defaultValue()
            cache = value
            return value
        }
        cache = decoded
        return decoded
    }

    public func save(_ value: Value) throws {
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        cache = value
    }

    public func delete() throws {
        cache = nil
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
