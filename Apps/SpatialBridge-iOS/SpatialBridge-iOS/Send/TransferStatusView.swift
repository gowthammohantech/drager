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

/// Preparing / Connecting / Transferring / Completed / Failed / Cancelled / Retrying
/// with accurate progress (bytes acknowledged by the Mac). Success appears only
/// after the Mac confirms durable storage (FR-209).
struct TransferStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let transfer = model.transfer
        Card {
            HStack(spacing: Tokens.Spacing.m) {
                icon(for: transfer.phase)
                    .font(.title2)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.phase.title).font(.headline)
                    Text(subtitle(transfer)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                actions(for: transfer.phase)
            }
            if showsProgress(transfer.phase) {
                ProgressView(value: transfer.fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Transfer progress")
                    .accessibilityValue(Text("\(Int(transfer.fraction * 100)) percent"))
                HStack {
                    Text("\(ByteCountFormatter.string(transfer.bytes)) of \(ByteCountFormatter.string(transfer.total))")
                    Spacer()
                    if transfer.bytesPerSecond > 0 {
                        Text("\(ByteCountFormatter.string(Int64(transfer.bytesPerSecond)))/s")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if transfer.phase == .failed, let error = transfer.error {
                ErrorBanner(error: error)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer.status")
    }

    @ViewBuilder
    private func icon(for phase: TransferPhase) -> some View {
        switch phase {
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.Palette.success)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Tokens.Palette.danger)
        case .cancelled: Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        case .retrying: Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Tokens.Palette.warning)
        case .connecting: Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.tint)
        default: ProgressView()
        }
    }

    @ViewBuilder
    private func actions(for phase: TransferPhase) -> some View {
        switch phase {
        case .preparing, .connecting, .transferring, .retrying:
            Button("Cancel", role: .cancel) { model.cancelTransfer() }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("transfer.cancel")
        case .failed, .cancelled:
            HStack {
                Button("Retry") { model.retry() }.buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityIdentifier("transfer.retry")
                Button { model.dismissTransfer() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.bordered).controlSize(.small).accessibilityLabel("Dismiss")
            }
        case .completed:
            Button { model.dismissTransfer() } label: { Image(systemName: "xmark") }
                .buttonStyle(.bordered).controlSize(.small).accessibilityLabel("Dismiss")
        case .verifying, .idle:
            EmptyView()
        }
    }

    private func showsProgress(_ phase: TransferPhase) -> Bool {
        switch phase {
        case .transferring, .verifying, .retrying: true
        default: false
        }
    }

    private func subtitle(_ transfer: TransferUIState) -> String {
        switch transfer.phase {
        case .completed:
            "\(transfer.savedName ?? transfer.filename) is on \(transfer.macName ?? "your computer")"
        case .verifying:
            "Checking integrity and saving \(transfer.filename)"
        case .connecting:
            "Waiting for \(model.link.peer?.displayName ?? "your computer")…"
        default:
            transfer.filename
        }
    }
}
