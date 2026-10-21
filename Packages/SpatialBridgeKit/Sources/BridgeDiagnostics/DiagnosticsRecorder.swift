import Foundation
public import BridgeModels
import os

public struct DiagnosticEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var category: LogCategory
    public var level: LogLevel
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), category: LogCategory, level: LogLevel, message: String) {
        self.id = id
        self.date = date
        self.category = category
        self.level = level
        self.message = message
    }
}

/// Performance metrics named after TD §11.
public enum MetricName: String, Codable, Sendable, CaseIterable {
    case discoveryDuration
    case pairingDuration
    case connectDuration
    case offerRoundTrip
    case firstByteLatency
    case throughputBytesPerSecond
    case verifyDuration
    case saveDuration
    case gestureToOfferLatency
    case overlayStartLatency
}

public struct MetricSample: Codable, Sendable, Hashable {
    public var name: MetricName
    public var value: Double
    public var date: Date
    public init(name: MetricName, value: Double, date: Date = Date()) {
        self.name = name
        self.value = value
        self.date = date
    }
}

/// Opt-in, local-first analytics events (PRD §7). Payloads carry only
/// durations, size buckets and error codes — never names or identities.
public struct AnalyticsEvent: Codable, Sendable, Hashable {
    public enum Name: String, Codable, Sendable, CaseIterable {
        case pairingStarted = "pairing_started"
        case pairingSucceeded = "pairing_succeeded"
        case gestureArmed = "gesture_armed"
        case gestureTriggered = "gesture_triggered"
        case transferStarted = "transfer_started"
        case transferCompleted = "transfer_completed"
        case transferFailed = "transfer_failed"
        case animationRendered = "animation_rendered"
    }

    public var name: Name
    public var date: Date
    public var durationSeconds: Double?
    public var sizeBucket: String?
    public var errorCode: BridgeError.Code?

    public init(name: Name, date: Date = Date(), durationSeconds: Double? = nil, sizeBucket: String? = nil, errorCode: BridgeError.Code? = nil) {
        self.name = name
        self.date = date
        self.durationSeconds = durationSeconds
        self.sizeBucket = sizeBucket
        self.errorCode = errorCode
    }
}

/// Process-wide ring buffer of recent events, metrics and analytics. Thread-safe
/// via an `OSAllocatedUnfairLock` so it can be called synchronously from loggers.
public final class DiagnosticsRecorder: Sendable {
    public static let shared = DiagnosticsRecorder()

    private struct State {
        var events: [DiagnosticEvent] = []
        var metrics: [MetricSample] = []
        var analytics: [AnalyticsEvent] = []
        var analyticsEnabled = false
        var minimumLevel: LogLevel = .debug
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    public let eventCapacity: Int
    public let metricCapacity: Int

    public init(eventCapacity: Int = 600, metricCapacity: Int = 400) {
        self.eventCapacity = eventCapacity
        self.metricCapacity = metricCapacity
    }

    public func record(category: LogCategory, level: LogLevel, message: String) {
        state.withLock { state in
            guard level >= state.minimumLevel else { return }
            state.events.append(DiagnosticEvent(category: category, level: level, message: message))
            if state.events.count > eventCapacity {
                state.events.removeFirst(state.events.count - eventCapacity)
            }
        }
    }

    public func record(metric name: MetricName, value: Double) {
        state.withLock { state in
            state.metrics.append(MetricSample(name: name, value: value))
            if state.metrics.count > metricCapacity {
                state.metrics.removeFirst(state.metrics.count - metricCapacity)
            }
        }
    }

    public func record(analytics event: AnalyticsEvent) {
        state.withLock { state in
            guard state.analyticsEnabled else { return }
            state.analytics.append(event)
            if state.analytics.count > metricCapacity {
                state.analytics.removeFirst(state.analytics.count - metricCapacity)
            }
        }
    }

    public func setAnalyticsEnabled(_ enabled: Bool) {
        state.withLock { $0.analyticsEnabled = enabled }
    }

    public func setMinimumLevel(_ level: LogLevel) {
        state.withLock { $0.minimumLevel = level }
    }

    public var recentEvents: [DiagnosticEvent] { state.withLock { $0.events } }
    public var metrics: [MetricSample] { state.withLock { $0.metrics } }
    public var analytics: [AnalyticsEvent] { state.withLock { $0.analytics } }

    public func clear() {
        state.withLock { state in
            state.events.removeAll()
            state.metrics.removeAll()
            state.analytics.removeAll()
        }
    }

    /// Summary statistics for a metric: count, p50, p95, max.
    public func summary(for name: MetricName) -> MetricSummary? {
        let values = metrics.filter { $0.name == name }.map(\.value).sorted()
        guard !values.isEmpty else { return nil }
        func percentile(_ p: Double) -> Double {
            let index = Int((Double(values.count - 1) * p).rounded())
            return values[max(0, min(values.count - 1, index))]
        }
        return MetricSummary(name: name, count: values.count, p50: percentile(0.5), p95: percentile(0.95), max: values.last ?? 0)
    }
}

public struct MetricSummary: Codable, Sendable, Hashable {
    public var name: MetricName
    public var count: Int
    public var p50: Double
    public var p95: Double
    public var max: Double
}

/// Measures a duration and records it as a metric.
public struct MetricTimer: Sendable {
    public let name: MetricName
    private let start: ContinuousClock.Instant

    public init(_ name: MetricName) {
        self.name = name
        self.start = ContinuousClock.now
    }

    @discardableResult
    public func finish(recorder: DiagnosticsRecorder = .shared) -> Double {
        let elapsed = ContinuousClock.now - start
        let seconds = elapsed.timeInterval
        recorder.record(metric: name, value: seconds)
        return seconds
    }
}
