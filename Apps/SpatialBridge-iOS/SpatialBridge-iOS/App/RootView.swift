import BridgeModels
import BridgePersistence
import BridgeSecurity
import SwiftUI

/// Root of the iPhone app. Routes between onboarding and the main experience.
/// Phase 1 ships the shell with live identity and settings; feature screens
/// arrive in Phase 4.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        NavigationStack {
            List {
                Section("This iPhone") {
                    LabeledContent("Name", value: environment.deviceInfo.displayName)
                    LabeledContent("Model", value: environment.deviceInfo.model)
                    LabeledContent("Device ID", value: environment.identity.fingerprint)
                        .font(.body.monospaced())
                }
                Section("Setup") {
                    LabeledContent("Onboarding", value: settings.settings.hasCompletedOnboarding ? "Complete" : "Not started")
                    LabeledContent("Layout", value: settings.settings.layout.placement.displayName)
                }
                Section {
                    LabeledContent("Version", value: environment.appVersion)
                }
            }
            .navigationTitle("Spatial Bridge")
            .accessibilityIdentifier("root.list")
        }
    }
}
