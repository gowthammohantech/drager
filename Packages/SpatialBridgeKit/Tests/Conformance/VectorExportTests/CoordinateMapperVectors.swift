import CoreGraphics
import Foundation
import Testing
@testable import BridgeCalibration
@testable import BridgeModels

enum CoordinateMapperVectors {
    static func rect(_ r: CGRect) -> JV { ["x": .double(Double(r.minX)), "y": .double(Double(r.minY)), "width": .double(Double(r.width)), "height": .double(Double(r.height))] }
    static func point(_ p: CGPoint) -> JV { ["x": .double(Double(p.x)), "y": .double(Double(p.y))] }

    static func display(_ d: DisplayGeometry) -> JV {
        [
            "identifier": .string(d.identifier), "localizedName": .string(d.localizedName),
            "frame": rect(d.frame), "visibleFrame": rect(d.visibleFrame),
            "backingScaleFactor": .double(d.backingScaleFactor), "originIsBottomLeft": .bool(d.originIsBottomLeft), "isMain": .bool(d.isMain),
        ]
    }

    /// 1440×900, 25 pt menu bar, 70 pt Dock (as in CoordinateMapperTests).
    static let mainBL = DisplayGeometry(identifier: "main", localizedName: "Built-in", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805), backingScaleFactor: 2, isMain: true)
    static let mainTL = DisplayGeometry(identifier: "main", localizedName: "Built-in", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 805), backingScaleFactor: 2, originIsBottomLeft: false, isMain: true)
    static let external = DisplayGeometry(identifier: "ext", localizedName: "External", frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1415), backingScaleFactor: 1, isMain: false)
    static let above = DisplayGeometry(identifier: "above", localizedName: "Above", frame: CGRect(x: -200, y: 900, width: 1920, height: 1080), visibleFrame: CGRect(x: -200, y: 900, width: 1920, height: 1055), backingScaleFactor: 1, isMain: false)
    static let card = CGSize(width: 220, height: 120)

    static func cases() -> [VectorCase] {
        var out: [VectorCase] = []
        func add(_ name: String, layout: SpatialLayout, alignmentOffsetInput: Double, displays: [DisplayGeometry], position: Double, card: CGSize = card, restInset: Double = 24) {
            let gesture = ExitGesture(edge: layout.exitEdge, normalizedPosition: position, outwardVelocity: 900, travelDistance: 0, firedAt: Fixtures.date)
            var c: VectorCase = [
                "name": .string(name),
                "layout": [
                    "placement": .string(layout.placement.rawValue), "mirrored": .bool(layout.mirrored),
                    "alignmentOffsetInput": .double(alignmentOffsetInput), "alignmentOffset": .double(layout.alignmentOffset),
                    "macDisplayIdentifier": .optional(layout.macDisplayIdentifier),
                ],
                "displays": .array(displays.map(display)),
                "gesture": ["edge": .string(gesture.edge.rawValue), "normalizedPositionInput": .double(position), "normalizedPosition": .double(gesture.normalizedPosition)],
                "cardSize": ["width": .double(Double(card.width)), "height": .double(Double(card.height))],
                "restInset": .double(restInset),
                "mappedPosition": .double(CoordinateMapper.mapNormalizedPosition(gesture.normalizedPosition, layout: layout)),
                "tolerance": 1e-6,
            ]
            guard let selected = CoordinateMapper.selectDisplay(for: layout, in: displays) else {
                c["selectedDisplay"] = .null
                out.append(c)
                return
            }
            let p = CoordinateMapper.placement(for: gesture, layout: layout, display: selected, cardSize: card, restInset: restInset)
            c["selectedDisplay"] = .string(selected.identifier)
            c["expected"] = [
                "edge": .string(p.edge.rawValue), "entryPoint": point(p.entryPoint), "restPoint": point(p.restPoint),
                "cardFrame": rect(p.cardFrame), "normalizedPosition": .double(p.normalizedPosition),
            ]
            out.append(c)
        }

        for placement in PhonePlacement.allCases {
            for mirrored in [false, true] {
                for (originName, d) in [("bottom-left", mainBL), ("top-left", mainTL)] {
                    for position in [0.0, 0.2, 0.5, 1.0] {
                        add("\(placement.rawValue), mirrored \(mirrored), \(originName) origin, position \(position)",
                            layout: SpatialLayout(placement: placement, mirrored: mirrored), alignmentOffsetInput: 0, displays: [d], position: position)
                    }
                }
            }
        }
        for (offset, position) in [(0.1, 0.3), (0.2, 0.95), (-0.25, 0.1), (0.5, 0.5), (0.7, 0.2), (-0.9, 0.6)] {
            for placement in [PhonePlacement.below, .left] {
                add("offset \(offset), \(placement.rawValue), position \(position)",
                    layout: SpatialLayout(placement: placement, alignmentOffset: offset), alignmentOffsetInput: offset, displays: [mainBL], position: position)
            }
        }
        add("offset 0.2 with mirroring, position 0.3", layout: SpatialLayout(placement: .above, alignmentOffset: 0.2, mirrored: true), alignmentOffsetInput: 0.2, displays: [mainTL], position: 0.3)
        add("gesture position clamped from 1.7", layout: SpatialLayout(placement: .below), alignmentOffsetInput: 0, displays: [mainBL], position: 1.7)
        add("gesture position clamped from -0.4", layout: SpatialLayout(placement: .right), alignmentOffsetInput: 0, displays: [mainBL], position: -0.4)

        // Display selection.
        add("configured external display", layout: SpatialLayout(placement: .below, macDisplayIdentifier: "ext"), alignmentOffsetInput: 0, displays: [mainBL, external], position: 0.25)
        add("configured display missing falls back to main", layout: SpatialLayout(placement: .left, macDisplayIdentifier: "missing"), alignmentOffsetInput: 0, displays: [external, mainBL], position: 0.25)
        add("no main display falls back to first", layout: SpatialLayout(placement: .right), alignmentOffsetInput: 0, displays: [external, above], position: 0.75)
        add("display with negative origin", layout: SpatialLayout(placement: .above, macDisplayIdentifier: "above"), alignmentOffsetInput: 0, displays: [mainBL, above], position: 0.1)
        add("no displays", layout: .default, alignmentOffsetInput: 0, displays: [], position: 0.5)

        // Card clamping.
        add("card larger than visible frame", layout: SpatialLayout(placement: .below), alignmentOffsetInput: 0, displays: [mainBL], position: 0.5, card: CGSize(width: 2000, height: 1000))
        add("zero rest inset at corner", layout: SpatialLayout(placement: .left), alignmentOffsetInput: 0, displays: [mainTL], position: 1, restInset: 0)
        add("large rest inset", layout: SpatialLayout(placement: .above), alignmentOffsetInput: 0, displays: [mainBL], position: 0, restInset: 500)
        return out
    }
}
