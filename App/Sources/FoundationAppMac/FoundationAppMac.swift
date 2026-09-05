#if os(macOS)
import SwiftUI
import AppKit
import FoundationAppKit

@main
struct FoundationAppMac: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Foundation Model Scratchpad") {
            RootView()
                .frame(minWidth: 520, minHeight: 620)
        }
    }
}

/// A SwiftPM executable is not a bundled `.app`, so macOS never grants it the
/// `.regular` activation policy. SwiftUI still builds the scene and the window
/// is genuinely on screen — measured, one on-screen window before this fix — but
/// the process has no Dock icon, never becomes frontmost, and the window sits
/// behind everything already open. It looks exactly like the app failed to
/// launch. Claiming the policy explicitly is what makes it a normal foreground
/// app; a bundled `.app` gets this from its Info.plist for free.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#else
// This target is the Mac shell only. The package also declares iOS so that
// FoundationAppKit can be compiled for it, and an all-targets build for an iOS
// destination reaches this file too. An executable target needs an entry
// point on every platform it is compiled for; this one does nothing.
@main
struct FoundationAppMac {
    static func main() {}
}
#endif
