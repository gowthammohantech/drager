import CoreGraphics
import Foundation
import Testing
@testable import BridgeCalibration
@testable import BridgeModels

@Suite("Coordinate mapping")
struct CoordinateMapperTests {
    /// A 1440×900 main display with a 25pt menu bar and 70pt Dock, AppKit bottom-left origin.
    let display = DisplayGeometry(
        identifier: "main",
        localizedName: "Built-in",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805),
        backingScaleFactor: 2,
        isMain: true
    )
    let card = CGSize(width: 220, height: 120)

    @Test("Phone below Mac: flick top at x=0.25 arrives at bottom edge, x=0.25")
    func below() {
        let gesture = ExitGesture(edge: .top, normalizedPosition: 0.25, outwardVelocity: 900)
        let placement = CoordinateMapper.placement(for: gesture, layout: SpatialLayout(placement: .below), display: display, cardSize: card)
        #expect(placement.edge == .bottom)
        #expect(placement.entryPoint == CGPoint(x: 360, y: 0))
        #expect(placement.cardFrame.minY >= display.visibleFrame.minY)
        #expect(abs(placement.restPoint.x - 360) < 0.001)
        #expect(placement.cardFrame.maxY < display.visibleFrame.midY)
    }

    @Test("Phone above Mac: arrives at top edge below the menu bar")
    func above() {
        let gesture = ExitGesture(edge: .bottom, normalizedPosition: 0.5, outwardVelocity: 900)
        let placement = CoordinateMapper.placement(for: gesture, layout: SpatialLayout(placement: .above), display: display, cardSize: card)
        #expect(placement.edge == .top)
        #expect(placement.entryPoint == CGPoint(x: 720, y: 900))
        #expect(placement.cardFrame.maxY <= display.visibleFrame.maxY)
        #expect(placement.cardFrame.minY > display.visibleFrame.midY)
    }

    @Test("Phone left of Mac: vertical position is flipped for the bottom-left origin")
    func leftFlip() {
        // 0.2 from the top on the phone should be 0.2 from the top on the Mac → y = 900 * (1 - 0.2) = 720.
        let gesture = ExitGesture(edge: .right, normalizedPosition: 0.2, outwardVelocity: 900)
        let placement = CoordinateMapper.placement(for: gesture, layout: SpatialLayout(placement: .left), display: display, cardSize: card)
        #expect(placement.edge == .left)
        #expect(abs(placement.entryPoint.y - 720) < 0.001)
        #expect(placement.entryPoint.x == 0)
        #expect(placement.cardFrame.minX >= display.visibleFrame.minX)
    }

    @Test("Phone right of Mac with a top-left-origin display does not flip")
    func rightTopLeftOrigin() {
        var tl = display
        tl.originIsBottomLeft = false
        tl.visibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 805)
        let gesture = ExitGesture(edge: .left, normalizedPosition: 0.2, outwardVelocity: 900)
        let placement = CoordinateMapper.placement(for: gesture, layout: SpatialLayout(placement: .right), display: tl, cardSize: card)
        #expect(abs(placement.entryPoint.y - 180) < 0.001)
        #expect(placement.entryPoint.x == 1440)
        #expect(placement.cardFrame.maxX <= tl.visibleFrame.maxX)
    }

    @Test("Cards are clamped fully inside the visible frame at the extremes")
    func clamping() {
        for position in [0.0, 1.0] {
            let gesture = ExitGesture(edge: .top, normalizedPosition: position, outwardVelocity: 900)
            let placement = CoordinateMapper.placement(for: gesture, layout: SpatialLayout(placement: .below), display: display, cardSize: card)
            #expect(display.visibleFrame.contains(placement.cardFrame), "position \(position)")
        }
    }

    @Test("Alignment offset and mirroring adjust the mapped position")
    func offsets() {
        #expect(CoordinateMapper.mapNormalizedPosition(0.3, layout: SpatialLayout(alignmentOffset: 0.1)) == 0.4)
        #expect(CoordinateMapper.mapNormalizedPosition(0.95, layout: SpatialLayout(alignmentOffset: 0.2)) == 1)
        #expect(abs(CoordinateMapper.mapNormalizedPosition(0.3, layout: SpatialLayout(mirrored: true)) - 0.7) < 1e-9)
    }

    @Test("Display selection prefers the configured display, then main, then first")
    func displaySelection() {
        let second = DisplayGeometry(identifier: "ext", localizedName: "External", frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1415), backingScaleFactor: 1, isMain: false)
        #expect(CoordinateMapper.selectDisplay(for: SpatialLayout(macDisplayIdentifier: "ext"), in: [display, second])?.identifier == "ext")
        #expect(CoordinateMapper.selectDisplay(for: SpatialLayout(macDisplayIdentifier: "missing"), in: [second, display])?.identifier == "main")
        #expect(CoordinateMapper.selectDisplay(for: .default, in: [second])?.identifier == "ext")
        #expect(CoordinateMapper.selectDisplay(for: .default, in: []) == nil)
    }
}
