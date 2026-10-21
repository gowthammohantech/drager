import BridgeCore
import BridgeDiagnostics
import BridgeGesture
import BridgeModels
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import SwiftUI

/// Design tokens (PRD §10). Use these instead of literals so spacing, radius,
/// motion and semantic colours stay consistent across screens.
nonisolated enum Tokens {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 16
        static let tile: CGFloat = 12
        static let chip: CGFloat = 10
    }

    enum Size {
        /// Minimum touch target (HIG / PRD §10).
        static let minTouch: CGFloat = 44
        static let thumbnail: CGFloat = 108
    }

    enum Motion {
        static let arrival: Double = 0.28
        static func spring(_ reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.35, dampingFraction: 0.78)
        }
        static func standard(_ reduceMotion: Bool) -> Animation {
            reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: arrival)
        }
    }

    enum Palette {
        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red
        static let neutral = Color.secondary
        static let card = Color(.secondarySystemGroupedBackground)
        static let canvas = Color(.systemGroupedBackground)
    }
}

// MARK: - Components

/// Large, full-width primary action.
struct PrimaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.s) {
                if isLoading {
                    ProgressView().tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: Tokens.Size.minTouch)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: Tokens.Radius.tile))
        .disabled(isLoading)
    }
}

/// Rounded container used for grouped content.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) { content }
            .padding(Tokens.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
    }
}

/// Empty / error / permission state with an optional action.
struct StateMessageView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var tint: Color = .secondary
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .frame(minHeight: Tokens.Size.minTouch)
            }
        }
        .padding(Tokens.Spacing.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Inline error banner for a `BridgeError`.
struct ErrorBanner: View {
    let error: BridgeError
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tokens.Palette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(error.code.userMessage).font(.subheadline.weight(.semibold))
                Text(error.code.recoverySuggestion).font(.footnote).foregroundStyle(.secondary)
                Text(error.code.rawValue).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if let retry {
                Button("Retry", action: retry).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(Tokens.Spacing.m)
        .background(Tokens.Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Tokens.Radius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Coloured dot + label describing link state.
struct ConnectionBadge: View {
    let state: PeerConnectionState
    let quality: ConnectionQuality

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(label).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, Tokens.Spacing.s)
        .padding(.vertical, Tokens.Spacing.xs)
        .background(color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Connection: \(label)"))
    }

    private var color: Color {
        switch state {
        case .connected: quality == .poor ? Tokens.Palette.warning : Tokens.Palette.success
        case .discovering, .authenticating, .pairing, .reconnecting: Tokens.Palette.warning
        case .disconnected: Tokens.Palette.danger
        case .idle, .permissionPending: Tokens.Palette.neutral
        }
    }

    private var label: String {
        switch state {
        case .connected:
            switch quality {
            case .excellent: "Connected · Excellent"
            case .good: "Connected · Good"
            case .fair: "Connected · Fair"
            case .poor: "Connected · Weak"
            case .unknown: "Connected"
            }
        default:
            state.displayName
        }
    }
}

extension ByteCountFormatter {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
