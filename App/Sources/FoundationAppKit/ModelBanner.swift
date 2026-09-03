import SwiftUI
import FoundationCore

/// Names the model behind every tab.
///
/// Sits above the tab bar because every tab runs against the same model, and
/// no result is interpretable without knowing which model produced it. The
/// "Model" label is required: "AFM 3 Core Advanced" on its own reads as a
/// title, not as a fact about the process.
public struct ModelBanner: View {
    let status: StatusResponse?

    public init(status: StatusResponse?) {
        self.status = status
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Model")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(status?.variant ?? "Loading…")
                .font(.caption.weight(.medium))
            if let status, !status.available {
                Text("· \(status.message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

#Preview("Model banner states") {
    VStack(spacing: 0) {
        ModelBanner(status: nil)
        Divider()
        ModelBanner(status: StatusResponse(
            available: true, message: "Ready", variant: "AFM 3 Core Advanced",
            contextSize: 8192, supportsVision: true,
            supportsGuidedGeneration: true, supportsReasoning: false
        ))
        Divider()
        ModelBanner(status: StatusResponse(
            available: false, message: "Apple Intelligence is not enabled on this Mac",
            variant: "AFM 3 Core Advanced", contextSize: 8192, supportsVision: true,
            supportsGuidedGeneration: true, supportsReasoning: false
        ))
    }
    .frame(width: 420)
}
