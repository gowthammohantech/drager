import CoreGraphics
import Foundation
public import BridgeModels

/// Geometry of a Mac display, captured from `NSScreen` by the app layer so this
/// module stays AppKit-free.
public struct DisplayGeometry: Sendable, Hashable, Codable {
    /// Stable identifier (CGDisplay UUID string).
    public var identifier: String
    public var localizedName: String
    /// Full frame in the global coordinate space.
    public var frame: CGRect
    /// Frame excluding menu bar and Dock.
    public var visibleFrame: CGRect
    public var backingScaleFactor: Double
    /// `true` for AppKit global coordinates (origin bottom-left of the main display).
    public var originIsBottomLeft: Bool
    public var isMain: Bool

    public init(
        identifier: String,
        localizedName: String,
        frame: CGRect,
        visibleFrame: CGRect,
        backingScaleFactor: Double,
        originIsBottomLeft: Bool = true,
        isMain: Bool
    ) {
        self.identifier = identifier
        self.localizedName = localizedName
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScaleFactor = backingScaleFactor
        self.originIsBottomLeft = originIsBottomLeft
        self.isMain = isMain
    }
}

/// Where and how the arrival animation should play on the Mac.
public struct ArrivalPlacement: Sendable, Hashable {
    public var edge: Edge
    /// Point on the display's *full* frame edge where the item enters.
    public var entryPoint: CGPoint
    /// Point inside the visible frame where the item comes to rest.
    public var restPoint: CGPoint
    /// Clamped rect for the arrival card, fully inside `visibleFrame`.
    public var cardFrame: CGRect
    /// Position along the edge after mapping and clamping, `[0, 1]`.
    public var normalizedPosition: Double

    public init(edge: Edge, entryPoint: CGPoint, restPoint: CGPoint, cardFrame: CGRect, normalizedPosition: Double) {
        self.edge = edge
        self.entryPoint = entryPoint
        self.restPoint = restPoint
        self.cardFrame = cardFrame
        self.normalizedPosition = normalizedPosition
    }
}

/// Pure functions mapping a sender gesture to a receiver placement (FRD §6).
public enum CoordinateMapper {
    /// Maps the normalized position along the iPhone exit edge to the
    /// normalized position along the Mac arrival edge, in a top-left-origin
    /// convention, applying the user's alignment offset and mirroring.
    public static func mapNormalizedPosition(_ position: Double, layout: SpatialLayout) -> Double {
        var p = min(max(position, 0), 1)
        if layout.mirrored { p = 1 - p }
        p += layout.alignmentOffset
        return min(max(p, 0), 1)
    }

    /// Selects the display for a layout, falling back to the main display and then the first.
    public static func selectDisplay(for layout: SpatialLayout, in displays: [DisplayGeometry]) -> DisplayGeometry? {
        if let id = layout.macDisplayIdentifier, let match = displays.first(where: { $0.identifier == id }) {
            return match
        }
        return displays.first(where: \.isMain) ?? displays.first
    }

    /// Computes placement on `display` for a gesture, given the card size and the
    /// distance from the edge at which the card rests.
    public static func placement(
        for gesture: ExitGesture,
        layout: SpatialLayout,
        display: DisplayGeometry,
        cardSize: CGSize,
        restInset: Double = 24
    ) -> ArrivalPlacement {
        let edge = layout.arrivalEdge
        let mapped = mapNormalizedPosition(gesture.normalizedPosition, layout: layout)
        let frame = display.frame
        let visible = display.visibleFrame

        // Position along the edge in the display's *global* coordinate space.
        // Along-edge axis for horizontal edges is x (left→right in both conventions).
        // For vertical edges it is y, which must be flipped when the origin is bottom-left.
        let alongVertical: Double = display.originIsBottomLeft ? (1 - mapped) : mapped

        let entryPoint: CGPoint
        let restPoint: CGPoint
        switch edge {
        case .top, .bottom:
            let x = frame.minX + mapped * frame.width
            let isTopInGlobal = display.originIsBottomLeft ? (edge == .top) : (edge == .top)
            // In bottom-left origin, the top edge is maxY; in top-left origin, it is minY.
            let edgeY: Double
            let restY: Double
            if display.originIsBottomLeft {
                edgeY = isTopInGlobal ? frame.maxY : frame.minY
                restY = isTopInGlobal ? visible.maxY - restInset - cardSize.height / 2 : visible.minY + restInset + cardSize.height / 2
            } else {
                edgeY = isTopInGlobal ? frame.minY : frame.maxY
                restY = isTopInGlobal ? visible.minY + restInset + cardSize.height / 2 : visible.maxY - restInset - cardSize.height / 2
            }
            entryPoint = CGPoint(x: x, y: edgeY)
            restPoint = CGPoint(x: x, y: restY)
        case .left, .right:
            let y = frame.minY + alongVertical * frame.height
            let edgeX = edge == .left ? frame.minX : frame.maxX
            let restX = edge == .left ? visible.minX + restInset + cardSize.width / 2 : visible.maxX - restInset - cardSize.width / 2
            entryPoint = CGPoint(x: edgeX, y: y)
            restPoint = CGPoint(x: restX, y: y)
        }

        // Clamp the card fully inside the visible frame.
        var card = CGRect(
            x: restPoint.x - cardSize.width / 2,
            y: restPoint.y - cardSize.height / 2,
            width: cardSize.width,
            height: cardSize.height
        )
        card.origin.x = min(max(card.origin.x, visible.minX), max(visible.minX, visible.maxX - card.width))
        card.origin.y = min(max(card.origin.y, visible.minY), max(visible.minY, visible.maxY - card.height))

        return ArrivalPlacement(
            edge: edge,
            entryPoint: entryPoint,
            restPoint: CGPoint(x: card.midX, y: card.midY),
            cardFrame: card,
            normalizedPosition: mapped
        )
    }
}
