import Foundation

/// A validated spatial gesture, as transmitted to the receiver.
///
/// Coordinates are 2D and normalized: `normalizedPosition` is the position along
/// the exit edge in `[0, 1]`, measured left→right for horizontal edges and
/// top→bottom for vertical edges, in the *sender's* top-left-origin space.
/// `outwardVelocity` is in points per second and only drives animation intensity.
public struct ExitGesture: Codable, Sendable, Hashable {
    public var edge: Edge
    public var normalizedPosition: Double
    public var outwardVelocity: Double
    /// Total distance travelled during the drag, in points. Diagnostic only.
    public var travelDistance: Double
    /// Sender wall-clock time at which the gesture fired.
    public var firedAt: Date

    public init(
        edge: Edge,
        normalizedPosition: Double,
        outwardVelocity: Double,
        travelDistance: Double = 0,
        firedAt: Date = Date()
    ) {
        self.edge = edge
        self.normalizedPosition = min(max(normalizedPosition, 0), 1)
        self.outwardVelocity = max(outwardVelocity, 0)
        self.travelDistance = max(travelDistance, 0)
        self.firedAt = firedAt
    }

    /// Animation intensity in `[0, 1]`, derived from velocity. 500 pt/s → ~0.33, 1500 pt/s → 1.
    public var intensity: Double {
        min(max(outwardVelocity / 1500, 0), 1)
    }
}
