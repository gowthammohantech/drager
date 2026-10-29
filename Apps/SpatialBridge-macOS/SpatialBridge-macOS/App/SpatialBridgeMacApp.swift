import BridgeCalibration
import BridgeCore
import BridgeDiagnostics
import BridgeModels
import BridgeNetworking
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import SwiftUI
import UniformTypeIdentifiers

/// Drager for Mac: a menu-bar utility (LSUIElement) with a Settings window.
@main
struct SpatialBridgeMacApp: App {
    @State private var model: MacAppModel

    init() {
        let model = MacAppEnvironment.live()
        _model = State(initialValue: model)
        // Start at launch, not when the menu is first opened, so iPhones can connect immediately.
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(model)
        } label: {
            Label("Drager", systemImage: model.activeTransfer == nil ? "arrow.down.to.line.compact" : "arrow.down.circle.dotted")
                .accessibilityIdentifier("menubar.extra")
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .environment(model)
        }
    }
}
