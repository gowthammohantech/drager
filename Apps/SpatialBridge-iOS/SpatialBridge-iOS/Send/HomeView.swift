import BridgeCalibration
import BridgeCore
import BridgeDiagnostics
import BridgeGesture
import BridgeModels
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Main screen: connection status, picker shortcuts, the selected item on the
/// throw surface, the gallery strip and recent transfers.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showFileImporter = false
    @State private var showPairing = false

    var body: some View {
        @Bindable var gallery = model.gallery
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                StatusCard(showPairing: $showPairing)

                if let item = model.gallery.selectedItem {
                    SendStage(item: item)
                } else {
                    Card {
                        StateMessageView(
                            systemImage: "photo.stack", title: "Choose something to send",
                            message: "Pick photos or files, then flick them toward the \(model.settings.settings.layout.exitEdge.displayName.lowercased()) edge."
                        )
                    }
                    .accessibilityIdentifier("home.empty")
                }

                HStack(spacing: Tokens.Spacing.m) {
                    PhotosPicker(selection: $gallery.pickerSelection, maxSelectionCount: 20, matching: .any(of: [.images, .videos, .livePhotos]), preferredItemEncoding: .current) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity, minHeight: Tokens.Size.minTouch)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home.photos")
                    Button { showFileImporter = true } label: {
                        Label("Files", systemImage: "folder")
                            .frame(maxWidth: .infinity, minHeight: Tokens.Size.minTouch)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home.files")
                }

                if !model.gallery.items.isEmpty {
                    GalleryStrip()
                }

                RecentTransfers()
            }
            .padding(Tokens.Spacing.l)
        }
        .background(Tokens.Palette.canvas)
        .navigationTitle("Spatial Bridge")
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            model.gallery.importFiles(result)
        }
        .sheet(isPresented: $showPairing) {
            NavigationStack {
                DiscoverPeersView()
                    .navigationTitle("Pair a Computer")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPairing = false } } }
            }
        }
        .refreshable { model.reconnect(); await model.refreshStores() }
    }
}

/// Connected Mac, quality, and actionable disconnected states.
private struct StatusCard: View {
    @Binding var showPairing: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: Tokens.Spacing.m) {
                Image(systemName: model.link.isConnected ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                    .font(.title)
                    .foregroundStyle(model.link.isConnected ? Color.accentColor : .secondary)
                    .symbolEffect(.pulse, isActive: model.link.state == .discovering || model.link.state == .authenticating)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text(model.link.peer?.displayName ?? (model.hasPairedMac ? "Your computer" : "No computer paired"))
                        .font(.headline)
                        .accessibilityIdentifier("home.macName")
                    ConnectionBadge(state: model.link.state, quality: model.link.quality)
                }
                Spacer()
            }
            if !model.hasPairedMac {
                PrimaryButton(title: "Pair a Computer", systemImage: "plus") { showPairing = true }
                    .accessibilityIdentifier("home.pair")
            } else if let code = model.link.lastError, !model.link.isConnected {
                ErrorBanner(error: BridgeError(code), retry: model.reconnect)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.status")
    }
}

/// The selected item on the throw surface, plus the accessible Send button (FR-109).
private struct SendStage: View {
    let item: StagedItem
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            ThrowSurface(
                edge: model.settings.settings.layout.exitEdge,
                configuration: model.gestureConfiguration,
                enabled: item.isReady && !model.transfer.phase.isActive,
                onFire: { gesture in model.send(item, gesture: gesture) }
            ) {
                ItemCard(item: item)
            }
            .frame(height: 360)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(item.filename), \(item.kindDescription)"))
            .accessibilityHint("Flick toward the \(model.settings.settings.layout.exitEdge.displayName.lowercased()) edge to send, or use the Send button.")
            .accessibilityAction(named: "Send to computer") { model.send(item, gesture: nil) }
            .accessibilityIdentifier("home.throwSurface")

            if model.transfer.phase != .idle {
                TransferStatusView()
            }

            Button {
                model.send(item, gesture: nil)
            } label: {
                Label("Send to \(model.link.peer?.displayName ?? "computer")", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity, minHeight: Tokens.Size.minTouch)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!item.isReady || model.transfer.phase.isActive || !model.hasPairedMac)
            .accessibilityIdentifier("home.send")
        }
    }
}

/// Preview card for a staged item.
struct ItemCard: View {
    let item: StagedItem

    var body: some View {
        VStack(spacing: Tokens.Spacing.s) {
            ZStack {
                if let thumbnail = item.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                    Image(systemName: item.contentType.conforms(to: .image) ? "photo" : "doc").font(.largeTitle).foregroundStyle(.secondary)
                }
                if item.readiness == .loading {
                    ProgressView().padding().background(.thinMaterial, in: Circle())
                }
            }
            .frame(width: 180, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous))
            VStack(spacing: 2) {
                Text(item.filename).font(.footnote.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(metadata).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 180)
        }
        .padding(Tokens.Spacing.s)
        .background(.background, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }

    private var metadata: String {
        var parts = [item.kindDescription]
        if item.byteCount > 0 { parts.append(ByteCountFormatter.string(item.byteCount)) }
        if let size = item.pixelSize { parts.append("\(Int(size.width))×\(Int(size.height))") }
        return parts.joined(separator: " · ")
    }
}
