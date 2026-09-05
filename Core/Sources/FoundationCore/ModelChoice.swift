import Foundation

/// Which Apple Foundation Model answers a request.
///
/// Always chosen explicitly. The on-device model is the default everywhere, and
/// nothing here falls back to the cloud on its own — a silent fallback would
/// hide exactly the local failures this package exists to expose. A session is
/// bound to its model when it is created, like its instructions.
public enum ModelChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    /// `SystemLanguageModel.default`: the ~3B model on the device itself.
    case onDevice = "on_device"
    /// `PrivateCloudComputeLanguageModel`: the larger model on Apple's servers.
    /// Needs a network, has a usage quota, and reports a 32k context window
    /// and reasoning support where the on-device model has neither.
    case privateCloud = "private_cloud"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: return "On-device"
        case .privateCloud: return "Private Cloud Compute"
        }
    }
}
