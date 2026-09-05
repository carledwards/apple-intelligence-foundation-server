import SwiftUI
import FoundationAppKit

/// The bundled Mac shell. Every view lives in `FoundationAppKit`; this target
/// supplies the entry point and a signed bundle that can carry entitlements —
/// which the SwiftPM executable in `App/` cannot, and Private Cloud Compute
/// requires one.
@main
struct FoundationAppMacOS: App {
    var body: some Scene {
        WindowGroup("Foundation Model Scratchpad") {
            RootView()
                .frame(minWidth: 520, minHeight: 620)
        }
    }
}
