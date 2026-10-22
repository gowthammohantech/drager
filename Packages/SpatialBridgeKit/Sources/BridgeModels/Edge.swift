import Foundation

/// A screen edge. Used both for the iPhone exit edge and the Mac arrival edge.
public enum Edge: String, Codable, Sendable, CaseIterable, Hashable {
    case top
    case bottom
    case left
    case right

    /// The edge directly across the screen.
    public var opposite: Edge {
        switch self {
        case .top: .bottom
        case .bottom: .top
        case .left: .right
        case .right: .left
        }
    }

    /// `true` for top/bottom edges, whose along-edge axis is horizontal (x).
    public var isHorizontal: Bool {
        switch self {
        case .top, .bottom: true
        case .left, .right: false
        }
    }

    /// Unit vector pointing outward from the screen through this edge, in a
    /// top-left-origin coordinate system (y grows downward, as on iOS).
    public var outwardNormalTopLeftOrigin: (dx: Double, dy: Double) {
        switch self {
        case .top: (0, -1)
        case .bottom: (0, 1)
        case .left: (-1, 0)
        case .right: (1, 0)
        }
    }

    public var displayName: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .left: "Left"
        case .right: "Right"
        }
    }
}
