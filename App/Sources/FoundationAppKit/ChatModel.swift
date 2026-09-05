import Foundation
import Observation
import FoundationCore

/// Drives one conversation against a chosen Apple Foundation Model.
///
/// Talks to `InferenceService` in process. There is no HTTP here: the server in
/// this repo exists to reach the model from things that are not Swift, and an
/// app paying that cost would be paying it for nothing.
@MainActor
@Observable
public final class ChatModel {

    public enum Kind: Sendable {
        case user
        case model
        /// A failure is a message too. Rendering it inline keeps the thing that
        /// went wrong next to the prompt that caused it.
        case failure
    }

    public struct Message: Identifiable, Sendable {
        public let id = UUID()
        public let kind: Kind
        public let text: String
        public let at: Date
        /// The model that answered; nil for the user's own messages.
        public let model: ModelChoice?
        /// Set when this failure was the context window filling up, so the view
        /// can offer the restart rather than making the reader work it out.
        public let exhaustion: ContextExhaustion?

        public init(
            kind: Kind,
            text: String,
            at: Date = Date(),
            model: ModelChoice? = nil,
            exhaustion: ContextExhaustion? = nil
        ) {
            self.kind = kind
            self.text = text
            self.at = at
            self.model = model
            self.exhaustion = exhaustion
        }
    }

    public struct ContextExhaustion: Sendable {
        public let used: Int
        public let limit: Int
        public var overBy: Int { max(0, used - limit) }
    }

    /// A conversation that was retired, kept so the run that hit the wall stays
    /// readable. Pressing restart must not make the evidence disappear.
    public struct RetiredSession: Identifiable, Sendable {
        public let id = UUID()
        public let sessionId: String
        public let model: ModelChoice
        /// Kept so a past run stays interpretable — the same prompts under
        /// different instructions are different experiments.
        public let instructions: String?
        public let messages: [Message]
        public let endedAt: Date
        public let reason: String
    }

    private let service: InferenceService

    /// The system prompt a fresh launch starts with. A role, not a format: the
    /// output shape is the schema's job, and the same message reads well in
    /// both modes — Text gives a chatty shopping list, JSON gives the fields.
    ///
    /// The second sentence is what turns "pumpkin" into "1 can (15 oz) pure
    /// pumpkin puree" — a list you can shop from. Measured on the device model:
    /// "Thanksgiving dessert for 10, easy to make" yields a pumpkin pie with
    /// eight quantified ingredients, `servings: 10`, `vegetarian: true`.
    public static let defaultInstructions = """
        You are a kitchen helper. The user tells you what they want to cook and \
        for whom; you work out what they need. Be specific about ingredients: \
        give quantities, the form (fresh, canned, frozen, dried), and details \
        that matter such as unsweetened, low-fat, or gluten-free.
        """

    /// The model the live session runs on. A session is bound to its model
    /// when it is created, so changing this retires the conversation the same
    /// way changing the system prompt does.
    public var selectedModel: ModelChoice = .onDevice
    public private(set) var sessionId: String?
    /// Edited freely; only reaches the model when applied. A session fixes its
    /// instructions at construction, so applying necessarily starts a new one —
    /// the UI says so rather than hiding it.
    public var instructionsDraft: String = ChatModel.defaultInstructions
    public private(set) var appliedInstructions: String? = ChatModel.defaultInstructions

    /// The fields the seeded system prompt fills in — one of each type, so
    /// the editor's grammar is demonstrated by example. Descriptions are the
    /// model's guide for each field.
    public static let defaultSchemaText = """
        dish: string  the dish being made
        servings: integer  how many people it feeds
        ingredients: string[]  one item each, with quantity and form
        vegetarian: bool  true when nothing in it is meat or fish
        """

    /// When on, every message is answered as a JSON object shaped by
    /// `schemaText` — guided generation, so the structure is guaranteed. When
    /// off, the model answers in prose and the schema is ignored. Per message,
    /// not per session: switching does not restart anything.
    public var structuredOutput = true
    public var schemaText: String = ChatModel.defaultSchemaText

    /// Why `schemaText` cannot be used as written, or nil when it can.
    public var schemaProblem: String? { SchemaEditor.problem(in: schemaText) }

    /// The field names, for a one-line summary when the editor is collapsed.
    public var schemaSummary: String {
        (try? OutputSchema.parse(schemaText))?.fields.map(\.name).joined(separator: ", ") ?? "invalid"
    }

    public private(set) var messages: [Message] = []
    public private(set) var retired: [RetiredSession] = []
    public private(set) var usage: ContextUsage?
    public private(set) var status: [ModelChoice: StatusResponse] = [:]
    public private(set) var isSending = false

    public init(service: InferenceService = InferenceService()) {
        self.service = service
    }

    /// The models that can answer right now. A model counts as available
    /// until it is known not to be: status arrives a moment after launch, and
    /// an empty list in the meantime would flicker.
    public var availableModels: [ModelChoice] {
        ModelChoice.allCases.filter { status[$0]?.available ?? true }
    }

    /// Number of turns sent in this session — the fallback signal when the model
    /// refuses to count tokens, which it does for any transcript holding an image.
    public var turnCount: Int {
        messages.filter { $0.kind == .user }.count
    }

    /// True when the draft differs from what the live session was built with.
    public var instructionsDirty: Bool {
        instructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (appliedInstructions ?? "")
    }

    public func start() async {
        for model in ModelChoice.allCases {
            status[model] = await service.status(model: model)
        }
        if !availableModels.contains(selectedModel) {
            selectedModel = availableModels.first ?? .onDevice
        }
        if sessionId == nil {
            sessionId = await service.createSession(instructions: appliedInstructions, model: selectedModel)
            await refreshUsage()
        }
    }

    /// Called when `selectedModel` changes. The session is bound to the model
    /// it was created on, so a new model means a new session; the old
    /// conversation is retired, not lost.
    public func modelChanged() async {
        guard let sessionId, await service.model(for: sessionId) != selectedModel else { return }
        await newSession(instructions: appliedInstructions, reason: "Model changed")
    }

    /// Puts the drafted instructions in force. Retires the current conversation,
    /// because there is no way to change a session's instructions in place.
    public func applyInstructions() async {
        let trimmed = instructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        await newSession(instructions: trimmed.isEmpty ? nil : trimmed, reason: "Instructions changed")
    }

    public func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }

        // An edited system prompt applies on the first message of a session.
        // There is no conversation to retire yet, so applying costs nothing,
        // and the message always runs under the prompt on screen.
        if instructionsDirty, messages.isEmpty {
            await applyInstructions()
        }
        guard let sessionId else { return }

        isSending = true
        defer { isSending = false }
        messages.append(Message(kind: .user, text: prompt))

        do {
            let schema = structuredOutput ? try OutputSchema.parse(schemaText) : nil
            let response = try await service.generateResponse(
                for: prompt, sessionId: sessionId, schema: schema
            )
            messages.append(Message(kind: .model, text: response.response, model: selectedModel))
        } catch let error as InferenceError {
            if case .contextSizeExceeded(let used, let limit) = error {
                messages.append(Message(
                    kind: .failure,
                    text: error.reason,
                    model: selectedModel,
                    exhaustion: ContextExhaustion(used: used, limit: limit)
                ))
            } else {
                messages.append(Message(kind: .failure, text: error.reason, model: selectedModel))
            }
        } catch {
            messages.append(Message(kind: .failure, text: "\(error)", model: selectedModel))
        }
        await refreshUsage()
    }

    /// Retires the current conversation and begins a fresh one, keeping whatever
    /// instructions are already in force. The old messages move to `retired`
    /// rather than being dropped.
    public func restart(reason: String = "Restarted by hand") async {
        await newSession(instructions: appliedInstructions, reason: reason)
    }

    private func newSession(instructions: String?, reason: String) async {
        if let sessionId, !messages.isEmpty {
            retired.insert(
                RetiredSession(
                    sessionId: sessionId,
                    model: await service.model(for: sessionId) ?? selectedModel,
                    instructions: appliedInstructions,
                    messages: messages,
                    endedAt: Date(),
                    reason: reason
                ),
                at: 0
            )
        }
        if let sessionId {
            await service.deleteSession(sessionId)
        }
        messages = []
        appliedInstructions = instructions
        instructionsDraft = instructions ?? ""
        self.sessionId = await service.createSession(instructions: instructions, model: selectedModel)
        await refreshUsage()
    }

    public func refreshUsage() async {
        guard let sessionId else { return }
        usage = try? await service.contextUsage(sessionId: sessionId)
    }

    /// The current session as plain text. Model and system prompt lead, so
    /// the transcript carries what is needed to reproduce it.
    public var transcriptText: String {
        var lines: [String] = []
        lines.append("Model: \(status[selectedModel]?.variant ?? selectedModel.displayName)")
        lines.append("System prompt: \(appliedInstructions ?? "none")")
        if structuredOutput {
            lines.append("Output: JSON")
            for line in schemaText.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("  \(line.trimmingCharacters(in: .whitespaces))")
            }
        } else {
            lines.append("Output: text")
        }
        lines.append("")
        for message in messages {
            let who: String
            switch message.kind {
            case .user: who = "You"
            case .model: who = "Model"
            case .failure: who = "Failed"
            }
            lines.append("\(who): \(message.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}
