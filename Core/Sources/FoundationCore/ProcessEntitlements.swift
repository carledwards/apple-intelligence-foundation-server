import Foundation
#if os(macOS)
import Security
#endif

/// What this process is entitled to, read from its own code signature.
///
/// Private Cloud Compute requires `com.apple.developer.private-cloud-compute`.
/// The framework's `availability` does not check for it — it describes the
/// service — and a signed app that asks without it traps inside the
/// framework rather than throwing. So the entitlement has to be checked here,
/// before the model is ever offered.
enum ProcessEntitlements {
    static let privateCloudComputeKey = "com.apple.developer.private-cloud-compute"

    /// The Info.plist key an iOS app sets alongside the entitlement. iOS has
    /// no public API to read a process's own entitlements, so the project
    /// writes this key under the same build condition that attaches the
    /// entitlements file — simulator builds only — and the app reads it.
    static let infoPlistKey = "FoundationPrivateCloudCompute"

    /// True when the running process holds the Private Cloud Compute
    /// entitlement. On macOS this is read from the code signature, so an
    /// unsigned SwiftPM binary is correctly reported as lacking it. On iOS it
    /// is read from `Info.plist`, which the Xcode project sets only for the
    /// simulator: a device build carries no entitlement, installs with an
    /// ordinary profile, and offers the on-device model alone.
    static let hasPrivateCloudCompute: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, privateCloudComputeKey as CFString, nil)
        return (value as? Bool) ?? false
        #else
        return (Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? Bool) ?? false
        #endif
    }()
}
