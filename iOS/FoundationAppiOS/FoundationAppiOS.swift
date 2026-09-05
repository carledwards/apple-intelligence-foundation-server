import SwiftUI
import FoundationAppKit

/// The iOS shell. Every view lives in `FoundationAppKit`; this target supplies
/// the entry point and the app bundle the simulator and device require.
@main
struct FoundationAppiOS: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
