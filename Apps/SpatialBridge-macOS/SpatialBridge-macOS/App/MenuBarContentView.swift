import BridgeModels
import BridgePersistence
import BridgeSecurity
import SwiftUI

/// Popover shown from the menu bar icon. Phase 1 shows live identity and
/// settings; discovery, pairing and transfers land in Phase 5.
struct MenuBarContentView: View {
    @Environment(MacAppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.title2)
                Text("Spatial Bridge")
                    .font(.headline)
                Spacer()
                Toggle("Available", isOn: $settings.settings.isAvailable)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Available to paired iPhones")
            }
            Divider()
            LabeledContent("This Mac", value: environment.deviceInfo.displayName)
            LabeledContent("Device ID", value: environment.identity.fingerprint)
                .font(.body.monospaced())
            Divider()
            HStack {
                Button("Settings…") { openSettings() }
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit Spatial Bridge") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 320)
        .accessibilityIdentifier("menubar.content")
    }
}

struct MacSettingsView: View {
    @Environment(MacAppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Receiving") {
                Toggle("Available to paired iPhones", isOn: $settings.settings.isAvailable)
                Toggle("Show arrival animation", isOn: $settings.settings.overlayEnabled)
            }
            Section("About") {
                LabeledContent("Version", value: environment.appVersion)
                LabeledContent("Device ID", value: environment.identity.fingerprint)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 320)
    }
}
