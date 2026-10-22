import Foundation
public import BridgeModels

/// Exportable, privacy-scrubbed diagnostics (TD §11).
public struct DiagnosticBundle: Codable, Sendable {
    public struct Environment: Codable, Sendable {
        public var appVersion: String
        public var build: String
        public var platform: DevicePlatform
        public var osVersion: String
        public var deviceModel: String
        public var protocolVersion: Int
        public init(appVersion: String, build: String, platform: DevicePlatform, osVersion: String, deviceModel: String, protocolVersion: Int = BridgeProtocol.version) {
            self.appVersion = appVersion
            self.build = build
            self.platform = platform
            self.osVersion = osVersion
            self.deviceModel = deviceModel
            self.protocolVersion = protocolVersion
        }
    }

    public var generatedAt: Date
    public var environment: Environment
    public var events: [DiagnosticEvent]
    public var metrics: [MetricSummary]
    public var analytics: [AnalyticsEvent]

    public init(generatedAt: Date = Date(), environment: Environment, events: [DiagnosticEvent], metrics: [MetricSummary], analytics: [AnalyticsEvent]) {
        self.generatedAt = generatedAt
        self.environment = environment
        self.events = events
        self.metrics = metrics
        self.analytics = analytics
    }
}

public enum DiagnosticBundleExporter {
    /// Builds a scrubbed bundle from the shared recorder.
    public static func makeBundle(environment: DiagnosticBundle.Environment, recorder: DiagnosticsRecorder = .shared) -> DiagnosticBundle {
        let events = recorder.recentEvents.map { event in
            var copy = event
            copy.message = Scrubber.scrub(event.message)
            return copy
        }
        let metrics = MetricName.allCases.compactMap { recorder.summary(for: $0) }
        return DiagnosticBundle(environment: environment, events: events, metrics: metrics, analytics: recorder.analytics)
    }

    public static func encode(_ bundle: DiagnosticBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    /// Writes the bundle to a temporary `.json` file and returns its URL.
    public static func writeTemporaryFile(_ bundle: DiagnosticBundle) throws -> URL {
        let data = try encode(bundle)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpatialBridge-Diagnostics-\(Int(bundle.generatedAt.timeIntervalSince1970))")
            .appendingPathExtension("json")
        try data.write(to: url, options: [.atomic])
        return url
    }
}

/// Removes personal data patterns from free text before export.
public enum Scrubber {
    private static let patterns: [(NSRegularExpression, String)] = {
        func make(_ pattern: String, _ replacement: String) -> (NSRegularExpression, String) {
            // Patterns are static literals; a failure here is a programmer error.
            (try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), replacement)
        }
        return [
            make(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<ip>"),
            make(#"\b(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}\b"#, "<ip6>"),
            make(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
            make(#"/Users/[^/\s]+"#, "/Users/<user>"),
            make(#"/var/mobile/Containers/[^\s]+"#, "<container>"),
        ]
    }()

    public static func scrub(_ text: String) -> String {
        var result = text
        for (regex, replacement) in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
        }
        return result
    }
}
