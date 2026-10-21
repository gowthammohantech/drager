import BridgeCore
import BridgeDiagnostics
import BridgeGesture
import BridgeModels
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import SwiftUI

/// Welcome → Local Network explainer → Discover & pair → Calibration → Tutorial (PRD §3).
struct OnboardingFlow: View {
    enum Step: Int, CaseIterable {
        case welcome, localNetwork, discover, calibration, tutorial
    }

    @Environment(AppModel.self) private var model
    @State private var step: Step = .welcome

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .welcome: WelcomeStep { advance() }
                case .localNetwork: LocalNetworkStep { advance() }
                case .discover: DiscoverStep(onContinue: advance)
                case .calibration: CalibrationStep(onContinue: advance)
                case .tutorial: TutorialStep { finish() }
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .toolbar {
                if step != .welcome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome } }
                    }
                }
                ToolbarItem(placement: .principal) {
                    StepIndicator(current: step.rawValue, total: Step.allCases.count)
                }
            }
        }
    }

    private func advance() {
        if step == .localNetwork { model.start() }
        withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .tutorial }
    }

    private func finish() {
        model.settings.settings.hasCompletedOnboarding = true
        model.start()
    }
}

private struct StepIndicator: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(current + 1) of \(total)"))
    }
}

private struct WelcomeStep: View {
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var float = false

    var body: some View {
        VStack(spacing: Tokens.Spacing.xl) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.tint.opacity(0.12))
                    .frame(width: 160, height: 120)
                    .offset(y: -50)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .offset(y: float ? -70 : -20)
                    .opacity(float ? 0.6 : 1)
                Image(systemName: "iphone")
                    .font(.system(size: 72, weight: .thin))
                    .offset(y: 70)
            }
            .frame(height: 260)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { float = true }
            }
            VStack(spacing: Tokens.Spacing.m) {
                Text("Throw files to your Mac").font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text("Pick a photo or file, flick it toward your Mac, and watch it land. Everything stays on your local network.")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
            PrimaryButton(title: "Get Started", systemImage: "arrow.right", action: onContinue)
                .accessibilityIdentifier("onboarding.start")
        }
        .padding(Tokens.Spacing.xl)
        .accessibilityIdentifier("onboarding.welcome")
    }
}

private struct LocalNetworkStep: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                Image(systemName: "wifi").font(.system(size: 48)).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Find your Mac on this network").font(.title.bold())
                VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                    ExplainerRow(icon: "dot.radiowaves.left.and.right", title: "Local network access",
                                 text: "iOS will ask to let Spatial Bridge find devices on your Wi-Fi. It's needed to discover and connect to your Mac.")
                    ExplainerRow(icon: "lock.shield", title: "Private and direct",
                                 text: "Files go straight to your Mac over an encrypted connection. No account, no cloud, no upload.")
                    ExplainerRow(icon: "photo", title: "Only what you pick",
                                 text: "You choose each photo or file with the system picker. Spatial Bridge never reads your whole library.")
                }
            }
            .padding(Tokens.Spacing.xl)
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: "Continue", systemImage: "arrow.right", action: onContinue)
                .padding(Tokens.Spacing.xl)
                .accessibilityIdentifier("onboarding.localNetwork.continue")
        }
        .accessibilityIdentifier("onboarding.localNetwork")
    }
}

struct ExplainerRow: View {
    let icon: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DiscoverStep: View {
    let onContinue: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            DiscoverPeersView()
            if model.hasPairedMac {
                PrimaryButton(title: "Continue", systemImage: "arrow.right", action: onContinue)
                    .padding(Tokens.Spacing.xl)
                    .accessibilityIdentifier("onboarding.discover.continue")
            }
        }
        .navigationTitle("Pair with your Mac")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CalibrationStep: View {
    let onContinue: () -> Void

    var body: some View {
        CalibrationView()
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Continue", systemImage: "arrow.right", action: onContinue)
                    .padding(Tokens.Spacing.xl)
                    .background(.bar)
                    .accessibilityIdentifier("onboarding.calibration.continue")
            }
            .navigationTitle("Where is your iPhone?")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TutorialStep: View {
    let onFinish: () -> Void
    @State private var succeeded = false

    var body: some View {
        VStack(spacing: Tokens.Spacing.l) {
            Text(succeeded ? "Nice throw!" : "Try a practice throw")
                .font(.title2.bold())
                .contentTransition(.opacity)
            Text("Drag the card and flick it toward the highlighted edge. Practice throws don't send anything.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            PracticeCanvas(onFire: { succeeded = true })
                .frame(maxHeight: .infinity)
            PrimaryButton(title: succeeded ? "Start Sending" : "Skip Practice", systemImage: "checkmark", action: onFinish)
                .accessibilityIdentifier("onboarding.finish")
        }
        .padding(Tokens.Spacing.xl)
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.inline)
    }
}
