import SwiftUI
import FoundationCore

/// The model a tab runs against, as a menu of the models that can answer.
///
/// Every tab carries one, in the same place: no result is interpretable
/// without knowing which model produced it, and the "Model" label is
/// required — "AFM 3 Core Advanced" on its own reads as a title, not a fact
/// about the process. A model that is not available is simply not listed;
/// with one model left the menu has one entry.
public struct ModelMenu: View {
    @Binding var selection: ModelChoice
    let models: [ModelChoice]
    let status: [ModelChoice: StatusResponse]
    let disabled: Bool

    public init(
        selection: Binding<ModelChoice>,
        models: [ModelChoice],
        status: [ModelChoice: StatusResponse],
        disabled: Bool = false
    ) {
        self._selection = selection
        self.models = models
        self.status = status
        self.disabled = disabled
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text("Model")
                .font(.caption.weight(.semibold))
            // Named by variant, e.g. "AFM 3 Core Advanced".
            Picker("", selection: $selection) {
                ForEach(models) { choice in
                    Text(status[choice]?.variant ?? choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .disabled(disabled)
            Spacer()
        }
    }
}
