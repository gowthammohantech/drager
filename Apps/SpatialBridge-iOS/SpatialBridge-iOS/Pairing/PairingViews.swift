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
import UIKit

/// Lists computers on the network: paired ones and ones accepting pairing (BR-02).
struct DiscoverPeersView: View {
    @Environment(AppModel.self) private var model
    @State private var showTroubleshooting = false

    var body: some View {
        List {
            if model.link.lastError == .localNetworkDenied || model.link.state == .disconnected(reason: .localNetworkDenied) {
                Section {
                    StateMessageView(
                        systemImage: "wifi.exclamationmark", title: "Local Network access is off",
                        message: "Turn on Local Network for Spatial Bridge in Settings to find your computer.",
                        tint: Tokens.Palette.danger, actionTitle: "Open Settings",
                        action: { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    )
                }
                .accessibilityIdentifier("discover.permissionDenied")
            }

            Section {
                let pairable = model.discovered.filter { peer in
                    peer.acceptsPairing && !model.trustedPeers.contains { $0.peerID == peer.advertisedPeerID }
                }
                if pairable.isEmpty {
                    HStack(spacing: Tokens.Spacing.m) {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text("Looking for computers…").font(.body)
                            Text("Open Spatial Bridge on your computer and keep both devices on the same Wi-Fi.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, Tokens.Spacing.s)
                    .accessibilityIdentifier("discover.searching")
                } else {
                    ForEach(pairable) { peer in
                        Button { model.pair(with: peer) } label: {
                            PeerRow(name: peer.displayName, subtitle: peer.isCompatible ? "Ready to pair" : "Needs an update",
                                    systemImage: peer.platform?.symbolName ?? "desktopcomputer", trailing: "Pair")
                        }
                        .disabled(!peer.isCompatible)
                        .accessibilityHint("Starts pairing. You'll compare a code on both screens.")
                    }
                }
            } header: {
                Text("Nearby computers")
            } footer: {
                Button("Can't find your computer?") { showTroubleshooting = true }.font(.footnote)
            }

            if model.hasPairedMac {
                Section("Paired") {
                    ForEach(model.trustedPeers) { peer in
                        PeerRow(name: peer.displayName,
                                subtitle: model.link.peer?.peerID == peer.peerID ? model.link.state.displayName : "Paired",
                                systemImage: peer.platform.symbolName, trailing: nil)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover.list")
        .sheet(isPresented: $showTroubleshooting) { TroubleshootingView() }
    }
}

struct PeerRow: View {
    let name: String
    let subtitle: String
    let systemImage: String
    let trailing: String?

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.tint).frame(width: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if let trailing {
                Text(trailing).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
            }
        }
        .frame(minHeight: Tokens.Size.minTouch)
        .accessibilityElement(children: .combine)
    }
}

struct TroubleshootingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ExplainerRow(icon: "laptopcomputer", title: "Open Spatial Bridge on the computer", text: "Spatial Bridge must be running on your Mac or PC with Available turned on.")
                    ExplainerRow(icon: "wifi", title: "Same network", text: "Both devices need to be on the same Wi-Fi. Guest networks often block devices from seeing each other.")
                    ExplainerRow(icon: "network.badge.shield.half.filled", title: "VPNs and firewalls", text: "Some VPNs and router settings block local discovery. Try pausing the VPN.")
                    ExplainerRow(icon: "hand.raised", title: "Local Network permission", text: "On iPhone: Settings › Privacy & Security › Local Network. On Mac: System Settings › Privacy & Security › Local Network. On Windows, allow Spatial Bridge through the firewall on private networks.")
                }
            }
            .navigationTitle("Troubleshooting")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Code comparison and pairing progress (FR-107).
struct PairingSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack(spacing: Tokens.Spacing.xl) {
                switch model.pairing {
                case .idle:
                    EmptyView()
                case .connecting(let peer):
                    Spacer()
                    ProgressView().controlSize(.large)
                    Text("Connecting to \(peer.displayName)…").font(.headline)
                    Spacer()
                case .comparing(let prompt):
                    CodeComparison(prompt: prompt, waiting: false)
                case .waitingForMac(let prompt):
                    CodeComparison(prompt: prompt, waiting: true)
                case .succeeded(let peer):
                    Spacer()
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(Tokens.Palette.success)
                        .accessibilityHidden(true)
                    Text("Paired with \(peer.displayName)").font(.title2.bold()).multilineTextAlignment(.center)
                    Text("You can now throw files to this \(peer.platform.genericNoun).").foregroundStyle(.secondary)
                    Spacer()
                    PrimaryButton(title: "Done") { model.dismissPairing() }
                        .accessibilityIdentifier("pairing.done")
                case .failed(let error):
                    Spacer()
                    Image(systemName: "xmark.octagon.fill").font(.system(size: 64)).foregroundStyle(Tokens.Palette.danger)
                        .accessibilityHidden(true)
                    Text("Pairing didn't complete").font(.title2.bold())
                    ErrorBanner(error: error)
                    Spacer()
                    PrimaryButton(title: "OK") { model.dismissPairing() }
                }
            }
            .padding(Tokens.Spacing.xl)
            .navigationTitle("Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.pairing.isBusy || { if case .comparing = model.pairing { return true }; return false }() {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancelPairing() } }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct CodeComparison: View {
    let prompt: PairingPrompt
    let waiting: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Tokens.Spacing.xl) {
            Text("Does this code match the one on \(prompt.peer.displayName)?")
                .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(prompt.formattedCode)
                .font(.system(size: 52, weight: .bold, design: .monospaced))
                .kerning(4)
                .padding(.vertical, Tokens.Spacing.l)
                .padding(.horizontal, Tokens.Spacing.xl)
                .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                .accessibilityLabel(Text("Code \(prompt.shortAuthenticationString.map(String.init).joined(separator: " "))"))
                .accessibilityIdentifier("pairing.code")
            VStack(spacing: Tokens.Spacing.xs) {
                Label(prompt.peer.displayName, systemImage: prompt.peer.platform.symbolName).font(.subheadline)
                Text("Device ID \(prompt.peerFingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            if waiting {
                HStack(spacing: Tokens.Spacing.s) {
                    ProgressView()
                    Text("Waiting for you to confirm on \(prompt.peer.displayName)…").font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                PrimaryButton(title: "Codes Match", systemImage: "checkmark") { model.answerPairing(true) }
                    .accessibilityIdentifier("pairing.match")
                Button("They Don't Match", role: .destructive) { model.answerPairing(false) }
                    .frame(minHeight: Tokens.Size.minTouch)
                    .accessibilityIdentifier("pairing.mismatch")
            }
        }
    }
}
