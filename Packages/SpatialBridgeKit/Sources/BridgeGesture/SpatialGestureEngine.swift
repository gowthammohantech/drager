import CoreGraphics
import Foundation
public import BridgeModels

/// Lifecycle of one drag.
public enum GesturePhase: Sendable, Hashable {
    case idle
    case tracking
    case armed
    case fired
    case cancelled
    case rejected(GestureRejection)
}

/// Why a released drag did not fire.
public enum GestureRejection: String, Sendable, Hashable, Codable {
    case notInEdgeZone
    case tooSlow
    case tooShort
    case wrongDirection
    case notTracking
}

/// Result of feeding a sample to the engine.
public struct GestureUpdate: Sendable, Hashable {
    public var phase: GesturePhase
    public var velocity: Velocity
    public var outwardVelocity: Double
    public var distanceToEdge: Double
    public var travelDistance: Double
    /// Normalized position along the target edge of the current location.
    public var normalizedPosition: Double
    /// `true` exactly on the sample where the engine transitioned into `.armed`.
    public var didArm: Bool
}

/// Pure, platform-neutral gesture recognizer. Feed it samples in canvas-local
/// top-left-origin coordinates; it emits at most one `ExitGesture` per drag.
///
/// State machine: idle → tracking → armed → fired | cancelled | rejected.
public struct SpatialGestureEngine: Sendable {
    public var configuration: GestureConfiguration
    public var bounds: CGRect
    public var targetEdge: Edge

    public private(set) var phase: GesturePhase = .idle
    private var estimator: VelocityEstimator
    private var start: GestureSample?
    private var latest: GestureSample?
    private var travel: Double = 0
    private var hasFired = false

    public init(configuration: GestureConfiguration = .default, bounds: CGRect, targetEdge: Edge) {
        self.configuration = configuration
        self.bounds = bounds
        self.targetEdge = targetEdge
        self.estimator = VelocityEstimator(window: configuration.velocityWindow, minimumSamples: configuration.minimumSamples)
    }

    // MARK: Lifecycle

    /// Starts a new drag. Any previous drag is discarded.
    public mutating func begin(_ sample: GestureSample) -> GestureUpdate {
        reset()
        phase = .tracking
        start = sample
        latest = sample
        estimator.add(sample)
        return makeUpdate(didArm: false)
    }

    /// Feeds a movement sample. Arms when the touch enters the edge zone while moving outward.
    public mutating func update(_ sample: GestureSample) -> GestureUpdate {
        guard phase == .tracking || phase == .armed else {
            return makeUpdate(didArm: false)
        }
        if let latest {
            travel += hypot(sample.x - latest.x, sample.y - latest.y)
        }
        latest = sample
        estimator.add(sample)

        var didArm = false
        let inZone = distanceToEdge(sample.location) <= configuration.edgeZoneInset
        let outward = estimator.velocity.component(along: targetEdge.outwardNormalTopLeftOrigin)
        if inZone && outward > 0 {
            if phase == .tracking { didArm = true }
            phase = .armed
        } else if phase == .armed && !inZone {
            // Left the zone again: disarm but keep tracking.
            phase = .tracking
        }
        return makeUpdate(didArm: didArm)
    }

    /// Ends the drag. Returns an `ExitGesture` exactly once if the release qualifies.
    @discardableResult
    public mutating func end(_ sample: GestureSample) -> ExitGesture? {
        guard phase == .tracking || phase == .armed, !hasFired else {
            if phase == .idle || phase == .cancelled { phase = .rejected(.notTracking) }
            return nil
        }
        if let latest {
            travel += hypot(sample.x - latest.x, sample.y - latest.y)
        }
        latest = sample
        estimator.add(sample)

        let velocity = estimator.velocity
        let outward = velocity.component(along: targetEdge.outwardNormalTopLeftOrigin)
        let distance = distanceToEdge(sample.location)
        let projected = CGPoint(
            x: sample.x + velocity.dx * configuration.projectionTime,
            y: sample.y + velocity.dy * configuration.projectionTime
        )
        let crossesEdge = distance <= configuration.edgeZoneInset || isBeyondEdge(projected)

        if outward <= 0 {
            phase = .rejected(.wrongDirection)
            return nil
        }
        if !crossesEdge {
            phase = .rejected(.notInEdgeZone)
            return nil
        }
        if travel < configuration.minimumTravel {
            phase = .rejected(.tooShort)
            return nil
        }
        if outward < configuration.effectiveVelocityThreshold {
            phase = .rejected(.tooSlow)
            return nil
        }

        hasFired = true
        phase = .fired
        return ExitGesture(
            edge: targetEdge,
            normalizedPosition: normalizedPosition(of: sample.location),
            outwardVelocity: outward,
            travelDistance: travel,
            firedAt: Date(timeIntervalSince1970: sample.timestamp)
        )
    }

    /// Cancels the current drag (system interruption, view disappearance…).
    public mutating func cancel() {
        reset()
        phase = .cancelled
    }

    public mutating func reset() {
        phase = .idle
        estimator.reset()
        start = nil
        latest = nil
        travel = 0
        hasFired = false
    }

    // MARK: Geometry

    /// Shortest distance from `point` to the target edge, clamped at 0 when beyond it.
    public func distanceToEdge(_ point: CGPoint) -> Double {
        switch targetEdge {
        case .top: max(0, point.y - bounds.minY)
        case .bottom: max(0, bounds.maxY - point.y)
        case .left: max(0, point.x - bounds.minX)
        case .right: max(0, bounds.maxX - point.x)
        }
    }

    public func isBeyondEdge(_ point: CGPoint) -> Bool {
        switch targetEdge {
        case .top: point.y < bounds.minY
        case .bottom: point.y > bounds.maxY
        case .left: point.x < bounds.minX
        case .right: point.x > bounds.maxX
        }
    }

    /// Position along the target edge in `[0, 1]`, left→right or top→bottom.
    public func normalizedPosition(of point: CGPoint) -> Double {
        let value: Double
        if targetEdge.isHorizontal {
            value = bounds.width > 0 ? (point.x - bounds.minX) / bounds.width : 0.5
        } else {
            value = bounds.height > 0 ? (point.y - bounds.minY) / bounds.height : 0.5
        }
        return min(max(value, 0), 1)
    }

    private func makeUpdate(didArm: Bool) -> GestureUpdate {
        let velocity = estimator.velocity
        let location = latest?.location ?? .zero
        return GestureUpdate(
            phase: phase,
            velocity: velocity,
            outwardVelocity: velocity.component(along: targetEdge.outwardNormalTopLeftOrigin),
            distanceToEdge: distanceToEdge(location),
            travelDistance: travel,
            normalizedPosition: normalizedPosition(of: location),
            didArm: didArm
        )
    }
}

// MARK: - Synthetic traces (shared by tests and the calibration tutorial)

/// A recorded or synthesized sequence of samples for deterministic testing.
public struct GestureTrace: Codable, Sendable, Hashable {
    public var name: String
    public var bounds: CGRect
    public var targetEdge: Edge
    public var samples: [GestureSample]
    public var expectedToFire: Bool

    public init(name: String, bounds: CGRect, targetEdge: Edge, samples: [GestureSample], expectedToFire: Bool) {
        self.name = name
        self.bounds = bounds
        self.targetEdge = targetEdge
        self.samples = samples
        self.expectedToFire = expectedToFire
    }

    /// Builds a straight-line drag from `from` to `to` over `duration` seconds at a given sample rate.
    public static func linear(
        name: String,
        bounds: CGRect,
        targetEdge: Edge,
        from: CGPoint,
        to: CGPoint,
        duration: TimeInterval,
        sampleInterval: TimeInterval = 1.0 / 120.0,
        startTime: TimeInterval = 1_700_000_000,
        expectedToFire: Bool
    ) -> GestureTrace {
        let steps = max(2, Int((duration / sampleInterval).rounded()))
        var samples: [GestureSample] = []
        samples.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            samples.append(GestureSample(
                x: from.x + (to.x - from.x) * t,
                y: from.y + (to.y - from.y) * t,
                timestamp: startTime + duration * t
            ))
        }
        return GestureTrace(name: name, bounds: bounds, targetEdge: targetEdge, samples: samples, expectedToFire: expectedToFire)
    }

    /// Runs the trace through a fresh engine and returns the fired gesture, if any.
    public func run(configuration: GestureConfiguration = .default) -> (gesture: ExitGesture?, finalPhase: GesturePhase, armedCount: Int) {
        var engine = SpatialGestureEngine(configuration: configuration, bounds: bounds, targetEdge: targetEdge)
        guard let first = samples.first else { return (nil, .idle, 0) }
        var armedCount = 0
        _ = engine.begin(first)
        for sample in samples.dropFirst().dropLast() {
            if engine.update(sample).didArm { armedCount += 1 }
        }
        let last = samples.count > 1 ? samples[samples.count - 1] : first
        let gesture = engine.end(last)
        return (gesture, engine.phase, armedCount)
    }
}
