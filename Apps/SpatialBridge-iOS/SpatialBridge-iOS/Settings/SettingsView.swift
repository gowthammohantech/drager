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

/// Paired devices, preferred Mac, gesture sensitivity, calibration, history,
/// privacy, diagnostics and reset.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showPairing = false
    @State private var confirmReset = false
    @State private var diagnosticsURL: URL?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                if model.trustedPeers.isEmpty {
                    Text("No paired computers").foregroundStyle(.secondary)
                }
                ForEach(model.trustedPeers) { peer in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.displayName)
                            Text(PairingProtocol.fingerprint(of: peer.peerID)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isPreferred(peer) {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Preferred")
                        }
                    }
                    .swipeActions {
                        Button("Unpair", role: .destructive) { model.unpair(peer) }
                        if !isPreferred(peer) {
                            Button("Prefer") { model.setPreferred(peer) }.tint(.accentColor)
                        }
                    }
                    .contextMenu {
                        Button("Make Preferred", systemImage: "star") { model.setPreferred(peer) }
                        Button("Unpair", systemImage: "link.badge.minus", role: .destructive) { model.unpair(peer) }
                    }
                    .accessibilityAction(named: "Unpair") { model.unpair(peer) }
                    .accessibilityAction(named: "Make preferred") { model.setPreferred(peer) }
                }
                Button("Pair Another Computer", systemImage: "plus") { showPairing = true }
                    .accessibilityIdentifier("settings.pair")
            } header: {
                Text("Paired computers")
            } footer: {
                Text("Swipe a computer to unpair it. Unpair on the computer too to remove trust on both sides.")
            }

            Section {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    HStack {
                        Text("Sensitivity")
                        Spacer()
                        Text(sensitivityLabel(settings.settings.gestureSensitivity)).foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.settings.gestureSensitivity, in: 0.5...2.0, step: 0.1) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise").accessibilityLabel("Firm")
                    } maximumValueLabel: {
                        Image(systemName: "hare").accessibilityLabel("Easy")
                    }
                    .accessibilityIdentifier("settings.sensitivity")
                    Text("Needs a flick of \(Int(model.gestureConfiguration.effectiveVelocityThreshold)) pt/s toward the edge.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SensitivityPreview()
                    .frame(height: 180)
                    .listRowInsets(EdgeInsets())
                NavigationLink("Calibration") {
                    CalibrationView().navigationTitle("Calibration")
                }
            } header: {
                Text("Gesture")
            }

            Section("History") {
                Toggle("Keep transfer history", isOn: $settings.settings.keepHistory)
                    .onChange(of: settings.settings.keepHistory) { _, keep in if !keep { model.clearHistory() } }
                Button("Clear History", role: .destructive) { model.clearHistory() }
                    .disabled(model.history.isEmpty)
            }

            Section {
                Toggle("Share anonymous usage counts", isOn: Binding(
                    get: { settings.settings.analyticsOptIn },
                    set: { model.setAnalytics($0) }
                ))
                NavigationLink("Privacy Details") { PrivacyDetailsView() }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Usage counts stay on this iPhone and are only included in diagnostics you choose to share. They never include photos, filenames or network identities.")
            }

            Section {
                Button("Prepare Diagnostics…", systemImage: "stethoscope") { diagnosticsURL = model.exportDiagnostics() }
                if let diagnosticsURL {
                    ShareLink(item: diagnosticsURL) { Label("Share Diagnostics", systemImage: "square.and.arrow.up") }
                }
                LabeledContent("Device ID", value: model.identity.fingerprint).font(.footnote.monospaced())
                LabeledContent("Version", value: "\(model.appVersion) (\(model.buildNumber))")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Diagnostics are scrubbed of filenames, addresses and personal paths.")
            }

            Section {
                Button("Reset Spatial Bridge", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showPairing) {
            NavigationStack {
                DiscoverPeersView()
                    .navigationTitle("Pair a Computer")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPairing = false } } }
            }
        }
        .confirmationDialog("Reset Spatial Bridge?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Unpair All and Reset", role: .destructive) { model.resetEverything() }
        } message: {
            Text("This unpairs every computer, clears history and restores default settings.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.form")
    }

    private func isPreferred(_ peer: TrustedPeer) -> Bool {
        (model.settings.settings.preferredPeerID ?? model.trustedPeers.first?.peerID) == peer.peerID
    }

    private func sensitivityLabel(_ value: Double) -> String {
        switch value {
        case ..<0.8: "Firm"
        case ..<1.3: "Normal"
        default: "Easy"
        }
    }
}

/// Live preview of the current gesture threshold: flick the card to see if it fires.
private struct SensitivityPreview: View {
    @Environment(AppModel.self) private var model
    @State private var result = "Flick to test"

    var body: some View {
        ThrowSurface(edge: model.settings.settings.layout.exitEdge, configuration: model.gestureConfiguration, enabled: true, onFire: { gesture in
            result = "Fired at \(Int(gesture.outwardVelocity)) pt/s"
        }) {
            Text(result)
                .font(.footnote.weight(.semibold))
                .padding(Tokens.Spacing.m)
                .background(.tint.opacity(0.15), in: Capsule())
        }
        .background(Tokens.Palette.canvas)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gesture test area. \(result)")
    }
}

struct PrivacyDetailsView: View {
    var body: some View {
        List {
            ExplainerRow(icon: "photo", title: "Photos", text: "You pick items with the system photo picker. Spatial Bridge gets only those items and never needs full library access.")
            ExplainerRow(icon: "wifi", title: "Local Network", text: "Used to find and connect to your computer. Files travel directly between your devices, encrypted.")
            ExplainerRow(icon: "key", title: "Keys", text: "Pairing keys are stored in the Keychain on this device only. Unpairing deletes them.")
            ExplainerRow(icon: "clock", title: "History", text: "Only names, sizes and outcomes are kept, on this device. You can turn it off or clear it.")
            ExplainerRow(icon: "icloud.slash", title: "No cloud", text: "There is no account and no server. Nothing is uploaded.")
        }
        .navigationTitle("Privacy")
    }
}

/// Metadata-only transfer history.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.history.isEmpty {
                StateMessageView(systemImage: "clock", title: "No transfers yet", message: "Files you send appear here.")
                    .listRowBackground(Color.clear)
            }
            ForEach(model.history) { record in
                HStack(spacing: Tokens.Spacing.m) {
                    Image(systemName: icon(record.state))
                        .foregroundStyle(color(record.state))
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.filename).lineLimit(1).truncationMode(.middle)
                        Text("\(record.peerDisplayName) · \(ByteCountFormatter.string(record.byteCount)) · \(record.startedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let code = record.errorCode {
                            Text(code.userMessage).font(.caption).foregroundStyle(Tokens.Palette.danger)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("History")
        .toolbar {
            if !model.history.isEmpty {
                Button("Clear", role: .destructive) { model.clearHistory() }
            }
        }
        .task { await model.refreshStores() }
        .refreshable { await model.refreshStores() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.list")
    }

    private func icon(_ state: TransferState) -> String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .canceled: "xmark.circle"
        default: "arrow.up.circle"
        }
    }

    private func color(_ state: TransferState) -> Color {
        switch state {
        case .completed: Tokens.Palette.success
        case .failed: Tokens.Palette.danger
        default: .secondary
        }
    }
}

/// Recent transfers on the home screen.
struct RecentTransfers: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.history.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Text("Recent").font(.headline)
                ForEach(model.history.prefix(3)) { record in
                    HStack {
                        Image(systemName: record.state == .completed ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(record.state == .completed ? Tokens.Palette.success : Tokens.Palette.warning)
                            .accessibilityHidden(true)
                        Text(record.filename).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(record.startedAt.formatted(.relative(presentation: .numeric))).font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
