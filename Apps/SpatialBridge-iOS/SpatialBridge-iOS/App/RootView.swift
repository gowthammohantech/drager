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

/// Routes between onboarding and the main tabs.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.settings.settings.hasCompletedOnboarding {
                MainTabView()
                    .task { model.start() }
            } else {
                OnboardingFlow()
            }
        }
        .sheet(isPresented: Binding(
            get: { model.pairing.isActive },
            set: { presented in if !presented { model.cancelPairing() } }
        )) {
            PairingSheet()
                .interactiveDismissDisabled(model.pairing.isBusy)
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Send", systemImage: "arrow.up.forward.app") {
                NavigationStack { HomeView() }
            }
            .accessibilityIdentifier("tab.send")
            Tab("History", systemImage: "clock.arrow.circlepath") {
                NavigationStack { HistoryView() }
            }
            .accessibilityIdentifier("tab.history")
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
            .accessibilityIdentifier("tab.settings")
        }
    }
}

extension PairingUIState {
    /// Pairing is mid-flight and must not be swiped away accidentally.
    var isBusy: Bool {
        switch self {
        case .connecting, .waitingForMac: true
        default: false
        }
    }
}
