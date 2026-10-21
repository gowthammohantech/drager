import Foundation

/// Tunable gesture thresholds (PRD §5). Defaults are proposed values to be
/// validated on hardware; `sensitivity` is the user-facing knob.
public struct GestureConfiguration: Codable, Sendable, Hashable {
    /// Distance from the target edge (points) within which the gesture arms.
    public var edgeZoneInset: Double
    /// Outward velocity required at release, points/second, at sensitivity 1.0.
    public var minimumOutwardVelocity: Double
    /// Minimum total travel distance for a valid throw, points.
    public var minimumTravel: Double
    /// Window over which velocity is estimated, seconds.
    public var velocityWindow: TimeInterval
    /// Minimum samples needed before velocity is trusted.
    public var minimumSamples: Int
    /// User sensitivity multiplier, 0.5 (needs a hard flick) … 2.0 (very easy). Divides the velocity threshold.
    public var sensitivity: Double
    /// Seconds ahead to project the release point when deciding on an edge crossing.
    public var projectionTime: TimeInterval

    public init(
        edgeZoneInset: Double = 24,
        minimumOutwardVelocity: Double = 500,
        minimumTravel: Double = 60,
        velocityWindow: TimeInterval = 0.09,
        minimumSamples: Int = 3,
        sensitivity: Double = 1.0,
        projectionTime: TimeInterval = 0.08
    ) {
        self.edgeZoneInset = edgeZoneInset
        self.minimumOutwardVelocity = minimumOutwardVelocity
        self.minimumTravel = minimumTravel
        self.velocityWindow = velocityWindow
        self.minimumSamples = max(2, minimumSamples)
        self.sensitivity = min(max(sensitivity, 0.5), 2.0)
        self.projectionTime = projectionTime
    }

    public static let `default` = GestureConfiguration()

    /// Effective velocity threshold after applying sensitivity.
    public var effectiveVelocityThreshold: Double {
        minimumOutwardVelocity / sensitivity
    }
}
