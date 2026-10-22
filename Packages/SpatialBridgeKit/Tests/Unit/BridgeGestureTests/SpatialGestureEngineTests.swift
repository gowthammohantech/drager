import CoreGraphics
import Foundation
import Testing
@testable import BridgeGesture
@testable import BridgeModels

@Suite("Spatial gesture engine")
struct SpatialGestureEngineTests {
    /// iPhone-ish canvas: 390 × 600 points, top-left origin.
    let bounds = CGRect(x: 0, y: 0, width: 390, height: 600)

    @Test("T-04: a fast upward flick that reaches the top edge fires exactly once")
    func fastFlickFires() {
        let trace = GestureTrace.linear(name: "fast-up", bounds: bounds, targetEdge: .top, from: CGPoint(x: 195, y: 400), to: CGPoint(x: 160, y: 10), duration: 0.25, expectedToFire: true)
        let result = trace.run()
        let gesture = try! #require(result.gesture)
        #expect(gesture.edge == .top)
        #expect(gesture.outwardVelocity > 1000)
        #expect(abs(gesture.normalizedPosition - 160.0 / 390.0) < 0.01)
        #expect(gesture.travelDistance > 380)
        #expect(result.finalPhase == .fired)
        #expect(result.armedCount == 1)
    }

    @Test("T-03: a slow drag to the edge does not fire")
    func slowDragRejected() {
        let trace = GestureTrace.linear(name: "slow-up", bounds: bounds, targetEdge: .top, from: CGPoint(x: 195, y: 300), to: CGPoint(x: 195, y: 10), duration: 2.0, expectedToFire: false)
        let result = trace.run()
        #expect(result.gesture == nil)
        #expect(result.finalPhase == .rejected(.tooSlow))
    }

    @Test("A fast flick that stays far from the edge does not fire (accidental scroll)")
    func notInZoneRejected() {
        let trace = GestureTrace.linear(name: "mid-flick", bounds: bounds, targetEdge: .top, from: CGPoint(x: 195, y: 500), to: CGPoint(x: 195, y: 300), duration: 0.15, expectedToFire: false)
        let result = trace.run()
        #expect(result.gesture == nil)
        #expect(result.finalPhase == .rejected(.notInEdgeZone))
    }

    @Test("Short travel is rejected even when fast and in the zone")
    func tooShortRejected() {
        let trace = GestureTrace.linear(name: "short", bounds: bounds, targetEdge: .top, from: CGPoint(x: 195, y: 40), to: CGPoint(x: 195, y: 5), duration: 0.05, expectedToFire: false)
        let result = trace.run()
        #expect(result.gesture == nil)
        #expect(result.finalPhase == .rejected(.tooShort))
    }

    @Test("Moving toward the wrong edge is rejected")
    func wrongDirection() {
        let trace = GestureTrace.linear(name: "down", bounds: bounds, targetEdge: .top, from: CGPoint(x: 195, y: 100), to: CGPoint(x: 195, y: 590), duration: 0.2, expectedToFire: false)
        #expect(trace.run().finalPhase == .rejected(.wrongDirection))
    }

    @Test("Each edge works with its own normalized axis", arguments: Edge.allCases)
    func everyEdge(edge: Edge) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let target: CGPoint
        switch edge {
        case .top: target = CGPoint(x: 100, y: 5)
        case .bottom: target = CGPoint(x: 100, y: 595)
        case .left: target = CGPoint(x: 5, y: 150)
        case .right: target = CGPoint(x: 385, y: 150)
        }
        let trace = GestureTrace.linear(name: "edge-\(edge)", bounds: bounds, targetEdge: edge, from: center, to: target, duration: 0.2, expectedToFire: true)
        let gesture = try! #require(trace.run().gesture)
        #expect(gesture.edge == edge)
        let expected = edge.isHorizontal ? 100.0 / 390.0 : 150.0 / 600.0
        #expect(abs(gesture.normalizedPosition - expected) < 0.01)
    }

    @Test("Ending twice never fires twice (FR-108)")
    func singleFire() {
        var engine = SpatialGestureEngine(bounds: bounds, targetEdge: .top)
        let t0 = 1.0
        _ = engine.begin(GestureSample(x: 195, y: 400, timestamp: t0))
        for i in 1...20 {
            _ = engine.update(GestureSample(x: 195, y: 400 - Double(i) * 20, timestamp: t0 + Double(i) * 0.01))
        }
        let first = engine.end(GestureSample(x: 195, y: 2, timestamp: t0 + 0.21))
        let second = engine.end(GestureSample(x: 195, y: 2, timestamp: t0 + 0.22))
        #expect(first != nil)
        #expect(second == nil)
        #expect(engine.phase == .fired)
    }

    @Test("Cancel resets state so a later end does nothing")
    func cancel() {
        var engine = SpatialGestureEngine(bounds: bounds, targetEdge: .top)
        _ = engine.begin(GestureSample(x: 195, y: 400, timestamp: 0))
        _ = engine.update(GestureSample(x: 195, y: 20, timestamp: 0.1))
        #expect(engine.phase == .armed)
        engine.cancel()
        #expect(engine.phase == .cancelled)
        #expect(engine.end(GestureSample(x: 195, y: 2, timestamp: 0.15)) == nil)
    }

    @Test("Arming happens when entering the edge zone while moving outward, and disarms on leaving")
    func armingLifecycle() {
        var engine = SpatialGestureEngine(bounds: bounds, targetEdge: .top)
        _ = engine.begin(GestureSample(x: 195, y: 200, timestamp: 0))
        let a = engine.update(GestureSample(x: 195, y: 100, timestamp: 0.05))
        #expect(a.phase == .tracking && !a.didArm)
        let b = engine.update(GestureSample(x: 195, y: 20, timestamp: 0.10))
        #expect(b.phase == .armed && b.didArm)
        let c = engine.update(GestureSample(x: 195, y: 15, timestamp: 0.12))
        #expect(c.phase == .armed && !c.didArm)
        let d = engine.update(GestureSample(x: 195, y: 80, timestamp: 0.20))
        #expect(d.phase == .tracking)
    }

    @Test("Sensitivity lowers the effective threshold")
    func sensitivity() {
        let borderline = GestureTrace.linear(name: "borderline", bounds: bounds, targetEdge: .top, from: CGPoint(x: 195, y: 200), to: CGPoint(x: 195, y: 10), duration: 0.5, expectedToFire: false)
        #expect(borderline.run(configuration: GestureConfiguration(sensitivity: 1.0)).gesture == nil) // ~380 pt/s
        #expect(borderline.run(configuration: GestureConfiguration(sensitivity: 2.0)).gesture != nil) // threshold 250
        #expect(GestureConfiguration(sensitivity: 5).sensitivity == 2.0)
    }

    @Test("Bundled fixture traces behave as recorded")
    func fixtures() throws {
        let url = try #require(Bundle.module.url(forResource: "traces", withExtension: "json", subdirectory: "Fixtures"))
        let traces = try JSONDecoder().decode([GestureTrace].self, from: Data(contentsOf: url))
        #expect(traces.count >= 3)
        for trace in traces {
            let fired = trace.run().gesture != nil
            #expect(fired == trace.expectedToFire, "trace \(trace.name)")
        }
    }
}

@Suite("Velocity estimator")
struct VelocityEstimatorTests {
    @Test("Least squares recovers a constant velocity exactly")
    func constantVelocity() {
        var estimator = VelocityEstimator(window: 0.1, minimumSamples: 3)
        for i in 0..<10 {
            let t = Double(i) * 0.01
            estimator.add(GestureSample(x: 10 + 300 * t, y: 50 - 900 * t, timestamp: t))
        }
        let v = estimator.velocity
        #expect(abs(v.dx - 300) < 1e-6)
        #expect(abs(v.dy + 900) < 1e-6)
        #expect(abs(v.component(along: Edge.top.outwardNormalTopLeftOrigin) - 900) < 1e-6)
    }

    @Test("Window drops stale samples and keeps at least two")
    func windowing() {
        var estimator = VelocityEstimator(window: 0.05, minimumSamples: 3)
        estimator.add(GestureSample(x: 0, y: 0, timestamp: 0))
        estimator.add(GestureSample(x: 0, y: 0, timestamp: 0.01))
        estimator.add(GestureSample(x: 100, y: 0, timestamp: 1.0))
        estimator.add(GestureSample(x: 200, y: 0, timestamp: 1.01))
        #expect(estimator.sampleCount == 2)
        #expect(abs(estimator.velocity.dx - 10_000) < 1e-6)
    }

    @Test("Zero or single samples yield zero velocity, out-of-order samples are ignored")
    func degenerate() {
        var estimator = VelocityEstimator(window: 0.1, minimumSamples: 3)
        #expect(estimator.velocity == .zero)
        estimator.add(GestureSample(x: 1, y: 1, timestamp: 5))
        #expect(estimator.velocity == .zero)
        estimator.add(GestureSample(x: 9, y: 9, timestamp: 4))
        #expect(estimator.sampleCount == 1)
    }
}
