import SwiftUI
import FoundationCore

public struct ChatView: View {
    @State private var model = ChatModel()
    @State private var draft = ""
    @State private var showInstructions = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .task { await model.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.status?.variant ?? "Loading model…")
                        .font(.headline)
                    if let status = model.status, !status.available {
                        Text(status.message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                Button("Restart session") {
                    Task { await model.restart() }
                }
                .disabled(model.isSending)
            }
            instructionsSection
            ContextMeter(usage: model.usage, turns: model.turnCount)
            if !model.retired.isEmpty {
                Text("\(model.retired.count) retired session\(model.retired.count == 1 ? "" : "s") kept")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    /// The system channel, kept visible rather than buried in a settings sheet.
    /// Which framing you put here versus in the prompt changes the answer, so it
    /// belongs next to the conversation it is steering.
    @ViewBuilder
    private var instructionsSection: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showInstructions.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showInstructions ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("Instructions")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)

                if !showInstructions {
                    Text(model.appliedInstructions ?? "none")
                        .font(.caption)
                        .foregroundStyle(model.appliedInstructions == nil ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                if model.instructionsDirty {
                    Button("Apply") { Task { await model.applyInstructions() } }
                        .font(.caption)
                        .disabled(model.isSending)
                }
            }

            if showInstructions {
                TextField(
                    "Applied to every turn, e.g. \"You label camera frames. Answer with one word.\"",
                    text: $model.instructionsDraft,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .font(.callout)

                Text(model.instructionsDirty
                     ? "Applying starts a new session — a session's instructions are fixed when it is created. The current conversation is retired, not deleted."
                     : "In force for every turn. Costs context once rather than per prompt, and survives a reset.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if model.isSending {
                        ProgressView().padding(.leading, 4)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.messages.count) {
                if let last = model.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatModel.Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label(for: message.kind))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color(for: message.kind))
            Text(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // A context failure is the one case worth acting on directly, so the
            // remedy sits on the message instead of in a separate alert.
            if let exhaustion = message.exhaustion {
                HStack(spacing: 8) {
                    Text("Over budget by \(exhaustion.overBy) tokens")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Start a fresh session") {
                        Task { await model.restart(reason: "Context exhausted") }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(10)
        .background(color(for: message.kind).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func label(for kind: ChatModel.Kind) -> String {
        switch kind {
        case .user: return "You"
        case .model: return "Model"
        case .failure: return "Failed"
        }
    }

    private func color(for kind: ChatModel.Kind) -> Color {
        switch kind {
        case .user: return .accentColor
        case .model: return .secondary
        case .failure: return .red
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask the on-device model…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(send)
            Button("Send", action: send)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
        }
        .padding(12)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await model.send(text) }
    }
}
