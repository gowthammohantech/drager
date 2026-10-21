import BridgeCore
import BridgeDiagnostics
import BridgeGesture
import BridgeModels
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import SwiftUI
import UIKit

/// Drives `SpatialGestureEngine` from a SwiftUI drag (FR-103, FR-104).
///
/// The card follows the finger; entering the edge zone while moving outward
/// arms the gesture (glow + haptic); releasing fast enough past the edge fires
/// exactly once per drag (FR-108). Everything else springs back.
@Observable
@MainActor
final class ThrowController {
    var offset: CGSize = .zero
    var armed = false
    var flying = false
    var lastRejection: GestureRejection?
    var hapticArm = 0
    var hapticFire = 0
    var hapticReject = 0

    private var engine: SpatialGestureEngine?
    private var dragging = false

    func changed(_ value: DragGesture.Value, bounds: CGRect, edge: BridgeModels.Edge, configuration: GestureConfiguration) {
        let sample = GestureSample(location: value.location, timestamp: value.time.timeIntervalSince1970)
        if !dragging {
            dragging = true
            flying = false
            lastRejection = nil
            var fresh = SpatialGestureEngine(configuration: configuration, bounds: bounds, targetEdge: edge)
            _ = fresh.begin(GestureSample(location: value.startLocation, timestamp: value.time.timeIntervalSince1970 - 0.001))
            engine = fresh
        }
        guard var current = engine else { return }
        let update = current.update(sample)
        engine = current
        offset = value.translation
        if update.didArm {
            hapticArm += 1
            DiagnosticsRecorder.shared.record(analytics: AnalyticsEvent(name: .gestureArmed))
        }
        armed = update.phase == .armed
    }

    /// Returns the validated gesture if the release qualifies.
    func ended(_ value: DragGesture.Value) -> ExitGesture? {
        defer { dragging = false }
        guard var current = engine else { return nil }
        let gesture = current.end(GestureSample(location: value.location, timestamp: value.time.timeIntervalSince1970))
        engine = nil
        armed = false
        if let gesture {
            flying = true
            hapticFire += 1
            DiagnosticsRecorder.shared.record(analytics: AnalyticsEvent(name: .gestureTriggered))
            return gesture
        }
        if case .rejected(let reason) = current.phase {
            lastRejection = reason
            if reason != .notInEdgeZone { hapticReject += 1 }
        }
        offset = .zero
        return nil
    }

    func cancel() {
        engine?.cancel()
        engine = nil
        dragging = false
        armed = false
        offset = .zero
    }

    func reset() {
        flying = false
        offset = .zero
    }
}

/// The throwing surface with an edge affordance. `card` is the dragged content.
struct ThrowSurface<Card: View>: View {
    let edge: BridgeModels.Edge
    let configuration: GestureConfiguration
    let enabled: Bool
    let onFire: (ExitGesture) -> Void
    @ViewBuilder var card: Card

    @State private var controller = ThrowController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            ZStack {
                EdgeGlow(edge: edge, armed: controller.armed)
                card
                    .scaleEffect(controller.flying ? 0.6 : (controller.armed ? 0.92 : 1))
                    .opacity(controller.flying ? 0 : 1)
                    .offset(controller.flying ? flyOffset(in: proxy.size) : controller.offset)
                    .rotation3DEffect(.degrees(controller.armed && !reduceMotion ? 8 : 0), axis: tiltAxis)
                    .shadow(color: .black.opacity(controller.armed ? 0.25 : 0.12), radius: controller.armed ? 18 : 8, y: 6)
                    .animation(controller.flying ? .easeIn(duration: reduceMotion ? 0.15 : 0.32) : Tokens.Motion.spring(reduceMotion), value: controller.offset)
                    .animation(Tokens.Motion.spring(reduceMotion), value: controller.armed)
                    .animation(.easeIn(duration: reduceMotion ? 0.15 : 0.32), value: controller.flying)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("throwSurface"))
                            .onChanged { value in
                                guard enabled else { return }
                                controller.changed(value, bounds: bounds, edge: edge, configuration: configuration)
                            }
                            .onEnded { value in
                                guard enabled else { controller.cancel(); return }
                                if let gesture = controller.ended(value) {
                                    onFire(gesture)
                                    Task {
                                        try? await Task.sleep(for: .milliseconds(700))
                                        controller.reset()
                                    }
                                }
                            }
                    )
            }
            .coordinateSpace(.named("throwSurface"))
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: controller.hapticArm)
        .sensoryFeedback(.success, trigger: controller.hapticFire)
        .sensoryFeedback(.warning, trigger: controller.hapticReject)
        .overlay(alignment: .bottom) {
            if let rejection = controller.lastRejection, rejection != .notInEdgeZone {
                Text(hint(for: rejection))
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, Tokens.Spacing.m)
                    .padding(.vertical, Tokens.Spacing.xs)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, Tokens.Spacing.s)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .onDisappear { controller.cancel() }
    }

    private var tiltAxis: (x: CGFloat, y: CGFloat, z: CGFloat) {
        edge.isHorizontal ? (1, 0, 0) : (0, 1, 0)
    }

    private func flyOffset(in size: CGSize) -> CGSize {
        let n = edge.outwardNormalTopLeftOrigin
        return CGSize(width: controller.offset.width + n.dx * size.width, height: controller.offset.height + n.dy * size.height)
    }

    private func hint(for rejection: GestureRejection) -> String {
        switch rejection {
        case .tooSlow: "Flick a little faster"
        case .tooShort: "Drag a little further"
        case .wrongDirection: "Flick toward the \(edge.displayName.lowercased()) edge"
        case .notInEdgeZone, .notTracking: "Throw toward the glowing edge"
        }
    }
}

/// Glowing band on the exit edge; brighter when armed.
struct EdgeGlow: View {
    let edge: BridgeModels.Edge
    let armed: Bool

    var body: some View {
        let gradient = LinearGradient(colors: [Color.accentColor.opacity(armed ? 0.55 : 0.18), .clear], startPoint: start, endPoint: end)
        Rectangle()
            .fill(gradient)
            .frame(width: edge.isHorizontal ? nil : (armed ? 64 : 28), height: edge.isHorizontal ? (armed ? 64 : 28) : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.2), value: armed)
            .accessibilityHidden(true)
    }

    private var alignment: Alignment {
        switch edge {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private var start: UnitPoint {
        switch edge {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private var end: UnitPoint {
        switch edge {
        case .top: .bottom
        case .bottom: .top
        case .left: .trailing
        case .right: .leading
        }
    }
}

/// Onboarding practice: same engine, nothing is sent.
struct PracticeCanvas: View {
    let onFire: () -> Void
    @Environment(AppModel.self) private var model
    @State private var throwCount = 0

    var body: some View {
        ThrowSurface(edge: model.settings.settings.layout.exitEdge, configuration: model.gestureConfiguration, enabled: true, onFire: { _ in
            throwCount += 1
            onFire()
        }) {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 150, height: 190)
                .overlay {
                    VStack(spacing: Tokens.Spacing.s) {
                        Image(systemName: "photo").font(.largeTitle)
                        Text(throwCount == 0 ? "Throw me" : "Thrown \(throwCount)×").font(.headline)
                    }
                    .foregroundStyle(.white)
                }
        }
        .background(Tokens.Palette.canvas, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Practice card")
        .accessibilityAction(named: "Practice throw") {
            throwCount += 1
            onFire()
        }
        .accessibilityIdentifier("practice.canvas")
    }
}
