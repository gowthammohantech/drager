import SwiftUI

/// Spatial Bridge for Mac: a menu-bar utility (LSUIElement) with a settings window.
@main
struct SpatialBridgeMacApp: App {
    @State private var environment = MacAppEnvironment.live()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(environment)
                .environment(environment.settings)
        } label: {
            Label("Spatial Bridge", systemImage: "arrow.down.to.line.compact")
                .accessibilityIdentifier("menubar.extra")
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .environment(environment)
                .environment(environment.settings)
        }
    }
}
