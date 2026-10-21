import AppKit
import BridgeCalibration
import BridgeCore
import BridgeDiagnostics
import BridgeModels
import BridgeNetworking
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// Transparent, borderless, click-through panel (TD §8, FR-204, ADR-008).
/// It never becomes key or main, so focus stays in the user's active app,
/// and it joins every Space including full-screen ones.
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What the overlay currently shows.
enum ArrivalPhase: Equatable {
    case incoming(progress: Double)
    case verifying
    case saved(name: String)
    case failed(BridgeError.Code)
}

@Observable
@MainActor
final class ArrivalViewState {
    var filename = ""
    var kindSymbol = "doc"
    var phase: ArrivalPhase = .incoming(progress: 0)
    var thumbnail: NSImage?
    /// Card centre in panel coordinates (top-left origin); animated from entry to rest.
    var position: CGPoint = .zero
    var restPosition: CGPoint = .zero
    var visible = false
    var reduceMotion = false
    var intensity: Double = 0.5
}

/// Places and animates the arrival card. Success is shown only after
/// `showSaved` (called on COMMITTED); everything before is provisional (AD §4).
@MainActor
final class ArrivalOverlayController {
    static let cardSize = CGSize(width: 300, height: 92)

    private let panel = OverlayPanel()
    private let state = ArrivalViewState()
    private var currentTransfer: UUID?
    private var hideTask: Task<Void, Never>?
    private let log = BridgeLogger(.overlay)

    init() {
        let host = NSHostingView(rootView: ArrivalCardContainer(state: state))
        host.sceneBridgingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
    }

    /// Screens as calibration geometry.
    static func displays() -> [DisplayGeometry] {
        NSScreen.screens.map { screen in
            DisplayGeometry(
                identifier: screen.displayUUID ?? "main",
                localizedName: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                backingScaleFactor: screen.backingScaleFactor,
                originIsBottomLeft: true,
                isMain: screen == NSScreen.main
            )
        }
    }

    /// Starts the provisional arrival (on TRANSFER_ACCEPT). Returns false if no display is available.
    @discardableResult
    func showIncoming(offer: TransferOffer, layout macLayout: SpatialLayout) -> Bool {
        let started = ContinuousClock.now
        hideTask?.cancel()
        let gesture = offer.gesture ?? ExitGesture(edge: .top, normalizedPosition: 0.5, outwardVelocity: 600)
        // The Mac's arrival edge follows the phone's exit edge; display and nudge are Mac preferences.
        let layout = SpatialLayout(
            placement: PhonePlacement.from(exitEdge: gesture.edge),
            macDisplayIdentifier: macLayout.macDisplayIdentifier,
            alignmentOffset: macLayout.alignmentOffset,
            mirrored: macLayout.mirrored
        )
        guard let display = CoordinateMapper.selectDisplay(for: layout, in: Self.displays()) else {
            log.error("No display for overlay")
            return false
        }
        let placement = CoordinateMapper.placement(for: gesture, layout: layout, display: display, cardSize: Self.cardSize)
        let entryRect = CGRect(x: placement.entryPoint.x - Self.cardSize.width / 2, y: placement.entryPoint.y - Self.cardSize.height / 2,
                               width: Self.cardSize.width, height: Self.cardSize.height)
        let panelFrame = placement.cardFrame.union(entryRect).insetBy(dx: -24, dy: -24).intersection(display.frame)
        panel.setFrame(panelFrame, display: false)

        func local(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - panelFrame.minX, y: panelFrame.maxY - point.y)
        }
        currentTransfer = offer.transferID
        state.filename = offer.filename
        state.kindSymbol = Self.symbol(for: offer.contentType)
        state.thumbnail = nil
        state.phase = .incoming(progress: 0)
        state.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        state.intensity = gesture.intensity
        state.restPosition = local(CGPoint(x: placement.cardFrame.midX, y: placement.cardFrame.midY))
        state.position = state.reduceMotion ? state.restPosition : local(placement.entryPoint)
        state.visible = false
        panel.orderFrontRegardless()

        let spring = Animation.spring(response: 0.42 - 0.12 * gesture.intensity, dampingFraction: 0.72)
        withAnimation(state.reduceMotion ? .easeOut(duration: 0.2) : spring) {
            state.visible = true
            state.position = state.restPosition
        }
        DiagnosticsRecorder.shared.record(metric: .overlayStartLatency, value: (ContinuousClock.now - started).timeInterval)
        DiagnosticsRecorder.shared.record(analytics: AnalyticsEvent(name: .animationRendered))
        return true
    }

    func showProgress(transferID: UUID, fraction: Double) {
        guard transferID == currentTransfer else { return }
        withAnimation(.linear(duration: 0.15)) { state.phase = .incoming(progress: fraction) }
    }

    func showVerifying(transferID: UUID) {
        guard transferID == currentTransfer else { return }
        state.phase = .verifying
    }

    /// Final success, only after durable save (FR-209).
    func showSaved(transferID: UUID, savedName: String, thumbnail: NSImage?) {
        guard transferID == currentTransfer else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            state.phase = .saved(name: savedName)
            state.thumbnail = thumbnail
        }
        scheduleHide(after: .seconds(2.2))
    }

    func showFailed(transferID: UUID, code: BridgeError.Code) {
        guard transferID == currentTransfer else { return }
        withAnimation(.easeInOut(duration: 0.2)) { state.phase = .failed(code) }
        scheduleHide(after: .seconds(3))
    }

    /// Preview from Settings › Overlay › Test.
    func test(layout: SpatialLayout, edge: BridgeModels.Edge) {
        let id = UUID()
        let offer = TransferOffer(
            transferID: id, sourcePeerID: PeerID(rawValue: "test"), targetPeerID: PeerID(rawValue: "test"),
            filename: "Test Photo.jpeg", contentType: "public.jpeg", byteCount: 1,
            sha256Hex: String(repeating: "0", count: 64),
            gesture: ExitGesture(edge: edge, normalizedPosition: 0.5, outwardVelocity: 900)
        )
        guard showIncoming(offer: offer, layout: layout) else { return }
        Task {
            for step in 1...5 {
                try? await Task.sleep(for: .milliseconds(120))
                showProgress(transferID: id, fraction: Double(step) / 5)
            }
            showSaved(transferID: id, savedName: offer.filename, thumbnail: nil)
        }
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.state.visible = false }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.panel.orderOut(nil)
            self.currentTransfer = nil
        }
    }

    static func symbol(for contentType: String) -> String {
        guard let type = UTType(contentType) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "archivebox" }
        return "doc"
    }
}

extension PhonePlacement {
    /// Inverse of `exitEdge`.
    static func from(exitEdge: BridgeModels.Edge) -> PhonePlacement {
        PhonePlacement.allCases.first { $0.exitEdge == exitEdge } ?? .below
    }
}

extension NSScreen {
    /// Stable identifier across reboots (CGDisplay UUID), used to remember the chosen display.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

// MARK: - SwiftUI card

private struct ArrivalCardContainer: View {
    @Bindable var state: ArrivalViewState

    var body: some View {
        GeometryReader { _ in
            ArrivalCard(state: state)
                .frame(width: ArrivalOverlayController.cardSize.width, height: ArrivalOverlayController.cardSize.height)
                .position(state.position)
                .opacity(state.visible ? 1 : 0)
                .scaleEffect(state.visible || state.reduceMotion ? 1 : 0.7)
        }
        .ignoresSafeArea()
    }
}

private struct ArrivalCard: View {
    @Bindable var state: ArrivalViewState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.12))
                if let thumbnail = state.thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: state.kindSymbol).font(.title2).foregroundStyle(.white)
                }
            }
            .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(state.filename).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.middle)
                progress
            }
            Spacer(minLength: 0)
            statusIcon
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.72))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch state.phase {
        case .incoming: "Receiving…"
        case .verifying: "Saving…"
        case .saved: "Saved"
        case .failed(let code): code.userMessage
        }
    }

    @ViewBuilder private var progress: some View {
        switch state.phase {
        case .incoming(let fraction):
            ProgressView(value: fraction).progressViewStyle(.linear).tint(.white)
        case .verifying:
            ProgressView().progressViewStyle(.linear).tint(.white)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch state.phase {
        case .saved:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}
