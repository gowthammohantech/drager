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

/// Horizontal strip of picked items with selection and readiness indicators.
struct GalleryStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack {
                Text("Selected").font(.headline)
                Text("\(model.gallery.readyCount) ready").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Clear", role: .destructive) { model.gallery.removeAll() }
                    .font(.subheadline)
                    .disabled(model.transfer.phase.isActive)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Tokens.Spacing.m) {
                    ForEach(model.gallery.items) { item in
                        GalleryTile(item: item, selected: item.id == model.gallery.selectedID)
                            .onTapGesture { model.gallery.select(item) }
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) { model.gallery.remove(item) }
                            }
                            .accessibilityAddTraits(item.id == model.gallery.selectedID ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction(named: "Remove") { model.gallery.remove(item) }
                    }
                }
                .padding(.vertical, Tokens.Spacing.xs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gallery.strip")
    }
}

struct GalleryTile: View {
    let item: StagedItem
    let selected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "doc").foregroundStyle(.secondary))
                }
            }
            .frame(width: Tokens.Size.thumbnail, height: Tokens.Size.thumbnail)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous)
                    .stroke(selected ? Color.accentColor : .clear, lineWidth: 3)
            )
            badge.padding(6)
        }
        .overlay(alignment: .bottom) {
            if case .tooLarge = item.readiness {
                Text("Too large").font(.caption2.weight(.semibold)).padding(4).background(.thinMaterial, in: Capsule()).padding(6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    @ViewBuilder private var badge: some View {
        switch item.readiness {
        case .loading:
            ProgressView().controlSize(.small).padding(4).background(.thinMaterial, in: Circle())
        case .ready:
            if selected {
                Image(systemName: "checkmark.circle.fill").font(.title3).symbolRenderingMode(.multicolor)
                    .background(Circle().fill(.white))
            }
        case .tooLarge:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Tokens.Palette.warning).background(Circle().fill(.white))
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Tokens.Palette.danger).background(Circle().fill(.white))
        }
    }

    private var accessibilityText: String {
        let state: String = switch item.readiness {
        case .loading: "loading"
        case .ready: "ready"
        case .tooLarge: "too large to send"
        case .failed(let reason): reason
        }
        return "\(item.filename), \(state)\(selected ? ", selected" : "")"
    }
}
