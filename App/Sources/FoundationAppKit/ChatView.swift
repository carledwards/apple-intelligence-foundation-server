import SwiftUI
import FoundationCore

public struct ChatView: View {
    @State private var model = ChatModel()
    @State private var draft = ""
    // Open by default. The seeded system prompt is the quickest explanation of
    // what the app is for, and it only explains anything if it can be seen.
    // On a phone it is collapsed to one line instead: expanded, it and the
    // keyboard leave no room for the conversation.
    @State private var showInstructions = true
    @State private var showSchema = true
    @FocusState private var composerFocused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

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
        // The system prompt is pre-filled, so the message is the only thing
        // left to type. Focus starts there.
        .onAppear {
            if sizeClass == .compact {
                showInstructions = false
                showSchema = false
            }
            composerFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            modelSection
            // Context sits directly under the model row. Both describe the
            // model's limits; the system prompt below is the user's own input.
            ContextMeter(usage: model.usage, turns: model.turnCount)
            instructionsSection
            outputSection
            HStack(spacing: 10) {
                if !model.retired.isEmpty {
                    Text("\(model.retired.count) retired session\(model.retired.count == 1 ? "" : "s") kept")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CopyButton(help: "Copy the conversation as text") { model.transcriptText }
                Button("Restart session") {
                    Task { await model.restart() }
                }
                .disabled(model.isSending)
            }
        }
        .padding(12)
    }

    /// The system prompt. The Foundation Models API calls it `instructions`;
    /// the label uses the industry term. It stays visible rather than in a
    /// settings sheet: which framing goes here versus in the message changes
    /// the answer, so it belongs next to the conversation it steers.
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
                        Text("System prompt")
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
                HStack(alignment: .top, spacing: 6) {
                    TextField(
                        "Optional, e.g. \"You are a camera-frame labeler. Answer with one word.\"",
                        text: $model.instructionsDraft,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                    .font(.callout)

                    if !model.instructionsDraft.isEmpty {
                        Button {
                            model.instructionsDraft = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 5)
                        .help("Clear the system prompt")
                    }
                }

                Text(instructionsHelp)
                    .font(.caption2)
                    .foregroundStyle(model.instructionsDirty && !model.messages.isEmpty ? Color.orange : Color.secondary)
            }
        }
    }

    /// Changing the model starts a new session, like changing the system
    /// prompt: a session is bound to its model when it is created.
    @ViewBuilder
    private var modelSection: some View {
        @Bindable var model = model
        ModelMenu(
            selection: $model.selectedModel,
            models: model.availableModels,
            status: model.status,
            disabled: model.isSending
        )
        .onChange(of: model.selectedModel) {
            Task { await model.modelChanged() }
        }
    }

    /// Text or JSON. JSON is guided generation: the framework builds the
    /// object and the model fills in the values, so the shape is guaranteed.
    /// Text leaves the model free, which is also where prompted JSON goes
    /// wrong — the two modes on the same prompt show the difference.
    @ViewBuilder
    private var outputSection: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSchema.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showSchema ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("Output")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)

                Picker("", selection: $model.structuredOutput) {
                    Text("Text").tag(false)
                    Text("JSON").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)

                if !showSchema, model.structuredOutput {
                    Text(model.schemaSummary)
                        .font(.caption)
                        .foregroundStyle(model.schemaProblem == nil ? .secondary : Color.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }

            if showSchema, model.structuredOutput {
                SchemaEditor(text: $model.schemaText, problem: model.schemaProblem)
            }
        }
    }

    private var instructionsHelp: String {
        if !model.instructionsDirty {
            return "Sent once at the start of the session and applies to every message. Counted against the context window once, not per message."
        }
        if model.messages.isEmpty {
            return "Applied when you send your first message."
        }
        return "Not applied yet. The system prompt is fixed when a session is created, so Apply starts a new session — the current conversation is kept, not deleted."
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
            Text(label(for: message))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color(for: message.kind))
            AnswerText(text: message.text)

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(for: message.kind).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func label(for message: ChatModel.Message) -> String {
        switch message.kind {
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
            TextField("Ask… e.g. \"Thanksgiving dessert for 10, easy to make\"", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($composerFocused)
                .onSubmit(send)
            // ⌘↩ is macOS-only. On iOS a key-command button whose enabled
            // state changes re-registers its key commands, and that resigns
            // the text field's first responder — so the field takes one
            // character, the button enables, and the keyboard drops.
            sendButton
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
        }
        .padding(12)
    }

    private var sendButton: some View {
        #if os(macOS)
        Button("Send", action: send)
            .keyboardShortcut(.return, modifiers: .command)
        #else
        Button("Send", action: send)
        #endif
    }

    private func send() {
        let text = draft
        draft = ""
        // Focus stays in the field across a Send click, so the next message
        // can be typed immediately.
        composerFocused = true
        Task { await model.send(text) }
    }
}
