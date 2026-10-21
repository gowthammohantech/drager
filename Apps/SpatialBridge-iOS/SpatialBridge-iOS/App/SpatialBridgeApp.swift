import SwiftUI

/// Spatial Bridge for iPhone.
@main
struct SpatialBridgeApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.settings)
        }
    }
}
