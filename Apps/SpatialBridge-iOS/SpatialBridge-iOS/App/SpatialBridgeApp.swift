import BridgeCore
import BridgeDiagnostics
import BridgeGesture
import BridgeModels
import BridgePersistence
import BridgeSecurity
import BridgeServices
import BridgeTransfer
import SwiftUI

/// Spatial Bridge for iPhone.
@main
struct SpatialBridgeApp: App {
    @State private var model = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    // Sending requires the foreground (BRD risk table); reconnect promptly on return.
                    if phase == .active, model.settings.settings.hasCompletedOnboarding { model.reconnect() }
                }
        }
    }
}
