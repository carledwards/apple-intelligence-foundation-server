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

    /// True when the running process holds the Private Cloud Compute
    /// entitlement. On macOS this is read from the code signature, so an
    /// unsigned SwiftPM binary is correctly reported as lacking it. iOS has no
    /// public API to read a process's own entitlements; there the answer is
    /// yes, because an iOS app that lacks the entitlement in its signing
    /// profile does not install on a device at all.
    static let hasPrivateCloudCompute: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, privateCloudComputeKey as CFString, nil)
        return (value as? Bool) ?? false
        #else
        return true
        #endif
    }()
}
