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
import SwiftUI
import UniformTypeIdentifiers

/// Menu bar popover: status, iPhones, destination, history, quick toggles, quit.
struct MenuBarContentView: View {
    @Environment(MacAppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.connectedPeers.isEmpty ? "iphone.slash" : "iphone.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(model.connectedPeers.isEmpty ? Color.secondary : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drager").font(.headline)
                    Text(model.statusSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("Available", isOn: Binding(get: { model.settings.settings.isAvailable }, set: { model.setAvailable($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Available to paired phones")
                    .accessibilityIdentifier("menubar.available")
            }

            if let activeTransfer = model.activeTransfer {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Receiving \(activeTransfer.filename)").font(.caption).lineLimit(1)
                    ProgressView(value: activeTransfer.fraction)
                }
            }

            if let problem = model.destinationProblem {
                Label {
                    VStack(alignment: .leading) {
                        Text(problem.code.userMessage).font(.caption.weight(.semibold))
                        Text(problem.code.recoverySuggestion).font(.caption2).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Button("Choose Folder…") { model.chooseDestination() }.controlSize(.small)
            }

            Divider()
            section("Phones") {
                if model.trustedPeers.isEmpty {
                    Text(model.settings.settings.allowNewPairings
                         ? "No paired phones. Open Drager on your phone to pair."
                         : "No paired phones. Turn on “Allow new pairings” in Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.trustedPeers) { peer in
                        let online = model.connectedPeers.contains { $0.peerID == peer.peerID }
                        HStack {
                            Circle().fill(online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Image(systemName: peer.platform.symbolName).font(.caption).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(peer.displayName).font(.callout)
                            Spacer()
                            Text(online ? "Connected" : "Offline").font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            section("Save to") {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(model.destinationPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not chosen")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(model.destinationPath == nil ? "Choose…" : "Change…") { model.chooseDestination() }
                        .controlSize(.small)
                        .accessibilityIdentifier("menubar.chooseFolder")
                }
            }

            if !model.history.isEmpty {
                section("Recent") {
                    ForEach(model.history.prefix(4)) { record in
                        Button { model.reveal(record) } label: {
                            HStack {
                                Image(systemName: record.state == .completed ? "checkmark.circle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(record.state == .completed ? Color.green : Color.orange)
                                    .accessibilityHidden(true)
                                Text(record.filename).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(record.startedAt.formatted(.relative(presentation: .numeric))).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .disabled(record.savedPath == nil)
                        .help(record.savedPath == nil ? (record.errorCode?.userMessage ?? "") : "Reveal in Finder")
                    }
                }
            }

            Divider()
            HStack {
                Button("Settings…") { NSApp.activate(); openSettings() }
                    .keyboardShortcut(",")
                    .accessibilityIdentifier("menubar.settings")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .accessibilityIdentifier("menubar.quit")
            }
        }
        .padding(16)
        .frame(width: 340)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar.content")
        .task { await model.refreshStores() }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }
}

/// Keyboard-accessible preferences (FR-201).
struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            DevicesSettings().tabItem { Label("Devices", systemImage: "iphone") }
            OverlaySettings().tabItem { Label("Arrival", systemImage: "sparkles.rectangle.stack") }
            HistorySettings().tabItem { Label("History", systemImage: "clock") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 400)
    }
}

private struct GeneralSettings: View {
    @Environment(MacAppModel.self) private var model

    var body: some View {
        Form {
            Section("Receiving") {
                Toggle("Available to paired phones", isOn: Binding(get: { model.settings.settings.isAvailable }, set: { model.setAvailable($0) }))
                Toggle("Allow new phones to pair", isOn: Binding(get: { model.settings.settings.allowNewPairings }, set: { model.setAllowPairing($0) }))
                LabeledContent("Save to") {
                    HStack {
                        Text(model.destinationPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not chosen")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseDestination() }
                        if model.destinationPath != nil { Button("Show") { model.revealDestination() } }
                    }
                }
            }
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.launchAtLoginNeedsApproval {
                    HStack {
                        Text("Approve Drager in Login Items.").font(.caption).foregroundStyle(.secondary)
                        Button("Open Login Items") { model.openLoginItemsSettings() }
                    }
                }
            }
            Section("Privacy") {
                Toggle("Keep anonymous usage counts", isOn: Binding(get: { model.settings.settings.analyticsOptIn }, set: { model.setAnalytics($0) }))
                Text("Counts stay on this Mac and appear only in diagnostics you export. They never include filenames or device identities.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DevicesSettings: View {
    @Environment(MacAppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.trustedPeers.isEmpty {
                    Text("No paired phones yet.").foregroundStyle(.secondary)
                }
                ForEach(model.trustedPeers) { peer in
                    HStack {
                        Image(systemName: peer.platform.symbolName).font(.title2).foregroundStyle(.tint)
                            .frame(width: 28)
                            .accessibilityLabel(peer.platform.displayName)
                        VStack(alignment: .leading) {
                            Text(peer.displayName)
                            Text("Device ID \(PairingProtocol.fingerprint(of: peer.peerID)) · paired \(peer.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unpair", role: .destructive) { model.unpair(peer) }
                    }
                }
            } header: {
                Text("Paired phones")
            } footer: {
                Text("Unpairing deletes the pairing key immediately. The phone can no longer connect until it pairs again.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct OverlaySettings: View {
    @Environment(MacAppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("Show arrival animation", isOn: Binding(get: { model.settings.settings.overlayEnabled }, set: { model.settings.settings.overlayEnabled = $0 }))
                Picker("Display", selection: Binding(get: { model.settings.settings.layout.macDisplayIdentifier ?? "" },
                                                     set: { model.setDisplay($0.isEmpty ? nil : $0) })) {
                    Text("Main display").tag("")
                    ForEach(ArrivalOverlayController.displays(), id: \.identifier) { display in
                        Text(display.localizedName).tag(display.identifier)
                    }
                }
                LabeledContent("Alignment") {
                    Slider(value: Binding(get: { model.settings.settings.layout.alignmentOffset },
                                          set: { model.settings.settings.layout.alignmentOffset = min(max($0, -0.5), 0.5) }),
                           in: -0.5...0.5, step: 0.05)
                }
                Button("Test Arrival") { model.testOverlay() }
            } header: {
                Text("Arrival")
            } footer: {
                Text("Files appear on the edge facing your phone, set on the phone under Calibration. If the animation can't be shown, you get a notification instead. Reduce Motion shows a simple card.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct HistorySettings: View {
    @Environment(MacAppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            Table(model.history) {
                TableColumn("File") { Text($0.filename).lineLimit(1) }
                TableColumn("From") { Text($0.peerDisplayName) }
                TableColumn("Size") { Text(ByteCountFormatter.string(fromByteCount: $0.byteCount, countStyle: .file)) }.width(70)
                TableColumn("Result") { record in
                    Text(record.state == .completed ? "Saved" : (record.errorCode?.rawValue ?? record.state.rawValue))
                }.width(70)
            }
            .contextMenu(forSelectionType: TransferRecord.ID.self) { ids in
                if let id = ids.first, let record = model.history.first(where: { $0.id == id }), record.savedPath != nil {
                    Button("Reveal in Finder") { model.reveal(record) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let record = model.history.first(where: { $0.id == id }) { model.reveal(record) }
            }
            HStack {
                Toggle("Keep history", isOn: Binding(get: { model.settings.settings.keepHistory }, set: { model.settings.settings.keepHistory = $0 }))
                Spacer()
                Button("Clear History", role: .destructive) { model.clearHistory() }.disabled(model.history.isEmpty)
            }
        }
        .padding()
    }
}

private struct AboutSettings: View {
    @Environment(MacAppModel.self) private var model

    var body: some View {
        Form {
            LabeledContent("Version", value: "\(model.appVersion) (\(model.buildNumber))")
            LabeledContent("This Mac", value: model.device.displayName)
            LabeledContent("Device ID", value: model.identity.fingerprint).font(.body.monospaced())
            Button("Export Diagnostics…") { model.exportDiagnostics() }
            Text("Diagnostics are scrubbed of filenames, addresses and personal paths before export.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Floating window that asks the Mac user to compare the pairing code.
@MainActor
final class PairingWindowController {
    private weak var model: MacAppModel?
    private var window: NSWindow?

    init(model: MacAppModel) {
        self.model = model
    }

    func show() {
        guard let model else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Pair Phone"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentView = NSHostingView(rootView: PairingApprovalView().environment(model))
            self.window = window
        }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }
}

struct PairingApprovalView: View {
    @Environment(MacAppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            if let prompt = model.pendingPairing {
                Image(systemName: prompt.peer.platform.symbolName).font(.system(size: 40)).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Pair with \(prompt.peer.displayName)?").font(.title3.bold())
                Text("Make sure this code matches the one on \(prompt.peer.displayName).").foregroundStyle(.secondary)
                Text(prompt.formattedCode)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .accessibilityLabel(Text("Code \(prompt.shortAuthenticationString.map(String.init).joined(separator: " "))"))
                Text("Device ID \(prompt.peerFingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary)
                HStack {
                    Button("Don't Match", role: .destructive) { model.answerPairing(false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Codes Match") { model.answerPairing(true) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            } else if let result = model.lastPairingResult {
                Image(systemName: result.hasPrefix("Paired") ? "checkmark.seal.fill" : "xmark.octagon")
                    .font(.system(size: 40))
                    .foregroundStyle(result.hasPrefix("Paired") ? Color.green : Color.orange)
                Text(result).font(.title3.bold())
            } else {
                ProgressView()
                Text("Waiting for the other device to confirm…").foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 380, height: 300)
    }
}
