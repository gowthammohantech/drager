import CoreGraphics
import Foundation

/// A touch sample in canvas-local, top-left-origin coordinates.
public struct GestureSample: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var timestamp: TimeInterval

    public init(x: Double, y: Double, timestamp: TimeInterval) {
        self.x = x
        self.y = y
        self.timestamp = timestamp
    }

    public init(location: CGPoint, timestamp: TimeInterval) {
        self.init(x: location.x, y: location.y, timestamp: timestamp)
    }

    public var location: CGPoint { CGPoint(x: x, y: y) }
}

public struct Velocity: Sendable, Hashable {
    public var dx: Double
    public var dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    public static let zero = Velocity(dx: 0, dy: 0)
    public var magnitude: Double { (dx * dx + dy * dy).squareRoot() }

    /// Component along a unit normal.
    public func component(along normal: (dx: Double, dy: Double)) -> Double {
        dx * normal.dx + dy * normal.dy
    }
}

/// Deterministic velocity estimation over a sliding time window using a
/// least-squares linear fit of position against time. Falls back to a
/// two-point estimate when fewer than `minimumSamples` are available.
public struct VelocityEstimator: Sendable {
    public var window: TimeInterval
    public var minimumSamples: Int
    private var samples: [GestureSample] = []

    public init(window: TimeInterval, minimumSamples: Int) {
        self.window = window
        self.minimumSamples = max(2, minimumSamples)
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    public mutating func add(_ sample: GestureSample) {
        // Ignore out-of-order timestamps.
        if let last = samples.last, sample.timestamp < last.timestamp { return }
        samples.append(sample)
        let cutoff = sample.timestamp - window
        // Keep at least two samples even if they are older than the window.
        while samples.count > 2, let first = samples.first, first.timestamp < cutoff {
            samples.removeFirst()
        }
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
    }

    public var sampleCount: Int { samples.count }

    /// Current estimate in points/second. `.zero` if fewer than two samples or no elapsed time.
    public var velocity: Velocity {
        guard samples.count >= 2, let first = samples.first, let last = samples.last else { return .zero }
        let elapsed = last.timestamp - first.timestamp
        guard elapsed > 0 else { return .zero }

        if samples.count < minimumSamples {
            return Velocity(dx: (last.x - first.x) / elapsed, dy: (last.y - first.y) / elapsed)
        }

        // Least squares slope: cov(t, p) / var(t)
        let n = Double(samples.count)
        let t0 = first.timestamp
        var sumT = 0.0, sumX = 0.0, sumY = 0.0, sumTT = 0.0, sumTX = 0.0, sumTY = 0.0
        for s in samples {
            let t = s.timestamp - t0
            sumT += t
            sumX += s.x
            sumY += s.y
            sumTT += t * t
            sumTX += t * s.x
            sumTY += t * s.y
        }
        let denominator = n * sumTT - sumT * sumT
        guard denominator > 1e-12 else {
            return Velocity(dx: (last.x - first.x) / elapsed, dy: (last.y - first.y) / elapsed)
        }
        let dx = (n * sumTX - sumT * sumX) / denominator
        let dy = (n * sumTY - sumT * sumY) / denominator
        return Velocity(dx: dx, dy: dy)
    }
}
