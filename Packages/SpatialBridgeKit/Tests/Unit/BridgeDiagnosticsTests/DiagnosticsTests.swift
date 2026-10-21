import Foundation
import Testing
@testable import BridgeDiagnostics
@testable import BridgeModels

@Suite("Diagnostics")
struct DiagnosticsTests {
    @Test("Recorder keeps a bounded ring buffer and computes percentiles")
    func recorder() {
        let recorder = DiagnosticsRecorder(eventCapacity: 5, metricCapacity: 10)
        for i in 0..<12 {
            recorder.record(category: .transfer, level: .info, message: "event \(i)")
        }
        #expect(recorder.recentEvents.count == 5)
        #expect(recorder.recentEvents.first?.message == "event 7")

        for value in [1.0, 2.0, 3.0, 4.0, 100.0] {
            recorder.record(metric: .firstByteLatency, value: value)
        }
        let summary = recorder.summary(for: .firstByteLatency)
        #expect(summary?.count == 5)
        #expect(summary?.p50 == 3)
        #expect(summary?.max == 100)
        #expect(recorder.summary(for: .saveDuration) == nil)
    }

    @Test("Analytics are dropped unless opted in")
    func analyticsOptIn() {
        let recorder = DiagnosticsRecorder()
        recorder.record(analytics: AnalyticsEvent(name: .transferStarted, sizeBucket: "1-10MB"))
        #expect(recorder.analytics.isEmpty)
        recorder.setAnalyticsEnabled(true)
        recorder.record(analytics: AnalyticsEvent(name: .transferCompleted, durationSeconds: 1.2, sizeBucket: "1-10MB"))
        #expect(recorder.analytics.count == 1)
        #expect(recorder.analytics.first?.name == .transferCompleted)
    }

    @Test("Minimum level filters debug noise")
    func levels() {
        let recorder = DiagnosticsRecorder()
        recorder.setMinimumLevel(.notice)
        recorder.record(category: .ui, level: .debug, message: "noise")
        recorder.record(category: .ui, level: .error, message: "signal")
        #expect(recorder.recentEvents.map(\.message) == ["signal"])
        #expect(LogLevel.debug < LogLevel.fault)
    }

    @Test("Scrubber masks addresses, emails and home paths")
    func scrubber() {
        let text = "peer 192.168.0.125 fe80::1c2b:3d4e:5f60:7a8b user me@example.com at /Users/gowtham/Desktop/x.jpeg"
        let scrubbed = Scrubber.scrub(text)
        #expect(!scrubbed.contains("192.168.0.125"))
        #expect(!scrubbed.contains("me@example.com"))
        #expect(!scrubbed.contains("/Users/gowtham"))
        #expect(scrubbed.contains("/Users/<user>"))
        #expect(scrubbed.contains("<ip>"))
    }

    @Test("Redaction keeps only extension and a stable short hash")
    func redaction() {
        let a = Redaction.filename("IMG_0001.jpeg")
        let b = Redaction.filename("IMG_0001.jpeg")
        #expect(a == b)
        #expect(a.hasPrefix("***.jpeg ("))
        #expect(!a.contains("IMG_0001"))
        #expect(Redaction.filename("README") == "*** (\(Redaction.stableHash("README")))")
        #expect(Redaction.peer(PeerID(rawValue: String(repeating: "f", count: 32))) == "ffffffff")
    }

    @Test("Bundle export scrubs events and encodes as JSON")
    func bundle() throws {
        let recorder = DiagnosticsRecorder()
        recorder.record(category: .session, level: .info, message: "connected to 10.0.0.2")
        recorder.record(metric: .throughputBytesPerSecond, value: 12_000_000)
        let env = DiagnosticBundle.Environment(appVersion: "1.0", build: "1", platform: .macOS, osVersion: "27.0", deviceModel: "Mac")
        let bundle = DiagnosticBundleExporter.makeBundle(environment: env, recorder: recorder)
        #expect(bundle.events.first?.message == "connected to <ip>")
        #expect(bundle.metrics.contains { $0.name == .throughputBytesPerSecond })
        let data = try DiagnosticBundleExporter.encode(bundle)
        #expect(String(decoding: data, as: UTF8.self).contains("\"protocolVersion\" : 1"))
        let url = try DiagnosticBundleExporter.writeTemporaryFile(bundle)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Metric timer records a non-negative duration")
    func timer() {
        let recorder = DiagnosticsRecorder()
        let elapsed = MetricTimer(.verifyDuration).finish(recorder: recorder)
        #expect(elapsed >= 0)
        #expect(recorder.metrics.count == 1)
    }
}
