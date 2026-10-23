import Foundation

/// Where the user says the iPhone sits relative to the Mac display. This is a
/// user-defined spatial relationship (ADR-004), not measured positioning.
public enum PhonePlacement: String, Codable, Sendable, Hashable, CaseIterable {
    case below
    case above
    case left
    case right

    /// The iPhone edge the user flicks toward to "throw" into the Mac.
    public var exitEdge: Edge {
        switch self {
        case .below: .top
        case .above: .bottom
        case .left: .right
        case .right: .left
        }
    }

    /// The Mac edge where the file appears to arrive.
    public var arrivalEdge: Edge {
        switch self {
        case .below: .bottom
        case .above: .top
        case .left: .left
        case .right: .right
        }
    }

    public var displayName: String {
        switch self {
        case .below: "Below the computer"
        case .above: "Above the computer"
        case .left: "Left of the computer"
        case .right: "Right of the computer"
        }
    }
}

/// Persisted calibration. Shared by both apps so the mapping is symmetric.
public struct SpatialLayout: Codable, Sendable, Hashable {
    public var placement: PhonePlacement
    /// Stable identifier of the chosen Mac display (CGDisplay UUID string). `nil` = main display.
    public var macDisplayIdentifier: String?
    /// Manual alignment nudge along the arrival edge in normalized units, `-0.5...0.5`.
    public var alignmentOffset: Double
    /// If `true`, mirror the along-edge axis (for users who hold the phone rotated).
    public var mirrored: Bool

    public init(
        placement: PhonePlacement = .below,
        macDisplayIdentifier: String? = nil,
        alignmentOffset: Double = 0,
        mirrored: Bool = false
    ) {
        self.placement = placement
        self.macDisplayIdentifier = macDisplayIdentifier
        self.alignmentOffset = min(max(alignmentOffset, -0.5), 0.5)
        self.mirrored = mirrored
    }

    public static let `default` = SpatialLayout()

    public var exitEdge: Edge { placement.exitEdge }
    public var arrivalEdge: Edge { placement.arrivalEdge }
}
