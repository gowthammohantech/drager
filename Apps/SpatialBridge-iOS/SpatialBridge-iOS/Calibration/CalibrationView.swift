import BridgeCalibration
import BridgeCore
import BridgeDiagnostics
import BridgeGesture
import BridgeModels
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import SwiftUI

/// Spatial calibration (ADR-004): where the phone sits relative to the Mac,
/// alignment nudge and mirroring. Display selection happens on the Mac.
struct CalibrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                ArrangementDiagram(layout: settings.settings.layout)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .animation(Tokens.Motion.spring(reduceMotion), value: settings.settings.layout)
            }
            Section {
                Picker("iPhone position", selection: $settings.settings.layout.placement) {
                    ForEach(PhonePlacement.allCases, id: \.self) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("calibration.placement")
            } header: {
                Text("Your iPhone is…")
            } footer: {
                Text("You'll flick toward the \(settings.settings.layout.exitEdge.displayName.lowercased()) edge of your iPhone, and files arrive from the \(settings.settings.layout.arrivalEdge.displayName.lowercased()) edge of your computer.")
            }
            Section {
                VStack(alignment: .leading) {
                    Slider(value: $settings.settings.layout.alignmentOffset, in: -0.5...0.5, step: 0.05) {
                        Text("Alignment")
                    } minimumValueLabel: {
                        Image(systemName: "arrow.left").accessibilityLabel("Earlier")
                    } maximumValueLabel: {
                        Image(systemName: "arrow.right").accessibilityLabel("Later")
                    }
                    .accessibilityValue(Text(String(format: "%+.0f%%", settings.settings.layout.alignmentOffset * 100)))
                }
                Toggle("Mirror direction", isOn: $settings.settings.layout.mirrored)
            } header: {
                Text("Fine-tune")
            } footer: {
                Text("Shift where files appear along the computer's edge. This is your preference; Spatial Bridge doesn't sense where your devices physically are.")
            }
        }
    }
}

/// Schematic of the Mac display and the phone's position, with the arrival edge highlighted.
struct ArrangementDiagram: View {
    let layout: SpatialLayout

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let mac = CGRect(x: size.width / 2 - 80, y: size.height / 2 - 52, width: 160, height: 104)
            let phone = phoneRect(around: mac, in: size)
            ZStack {
                RoundedRectangle(cornerRadius: 10).stroke(.secondary, lineWidth: 2)
                    .frame(width: mac.width, height: mac.height).position(x: mac.midX, y: mac.midY)
                edgeHighlight(on: mac, edge: layout.arrivalEdge)
                Image(systemName: "desktopcomputer").font(.title).foregroundStyle(.secondary).position(x: mac.midX, y: mac.midY)
                RoundedRectangle(cornerRadius: 8).fill(.tint.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 2))
                    .frame(width: phone.width, height: phone.height).position(x: phone.midX, y: phone.midY)
                Image(systemName: "arrow.up").font(.headline).foregroundStyle(.tint)
                    .rotationEffect(rotation(for: layout.exitEdge))
                    .position(x: phone.midX, y: phone.midY)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("iPhone \(layout.placement.displayName.lowercased()); files arrive from the \(layout.arrivalEdge.displayName.lowercased()) edge of the computer"))
    }

    private func phoneRect(around mac: CGRect, in size: CGSize) -> CGRect {
        let w: CGFloat = 36, h: CGFloat = 64, gap: CGFloat = 18
        let shift = layout.alignmentOffset * (layout.placement == .left || layout.placement == .right ? mac.height : mac.width)
        switch layout.placement {
        case .below: return CGRect(x: mac.midX - w / 2 + shift, y: mac.maxY + gap, width: w, height: h)
        case .above: return CGRect(x: mac.midX - w / 2 + shift, y: mac.minY - gap - h, width: w, height: h)
        case .left: return CGRect(x: mac.minX - gap - w, y: mac.midY - h / 2 + shift, width: w, height: h)
        case .right: return CGRect(x: mac.maxX + gap, y: mac.midY - h / 2 + shift, width: w, height: h)
        }
    }

    @ViewBuilder
    private func edgeHighlight(on mac: CGRect, edge: BridgeModels.Edge) -> some View {
        let thickness: CGFloat = 4
        switch edge {
        case .top: Capsule().fill(.tint).frame(width: mac.width - 20, height: thickness).position(x: mac.midX, y: mac.minY)
        case .bottom: Capsule().fill(.tint).frame(width: mac.width - 20, height: thickness).position(x: mac.midX, y: mac.maxY)
        case .left: Capsule().fill(.tint).frame(width: thickness, height: mac.height - 20).position(x: mac.minX, y: mac.midY)
        case .right: Capsule().fill(.tint).frame(width: thickness, height: mac.height - 20).position(x: mac.maxX, y: mac.midY)
        }
    }

    private func rotation(for edge: BridgeModels.Edge) -> Angle {
        switch edge {
        case .top: .zero
        case .right: .degrees(90)
        case .bottom: .degrees(180)
        case .left: .degrees(-90)
        }
    }
}
