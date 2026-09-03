import Foundation
import Observation
import FoundationCore

/// Drives one conversation against the on-device model.
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
        /// Set when this failure was the context window filling up, so the view
        /// can offer the restart rather than making the reader work it out.
        public let exhaustion: ContextExhaustion?

        public init(kind: Kind, text: String, at: Date = Date(), exhaustion: ContextExhaustion? = nil) {
            self.kind = kind
            self.text = text
            self.at = at
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
        /// Kept so a past run stays interpretable — the same prompts under
        /// different instructions are different experiments.
        public let instructions: String?
        public let messages: [Message]
        public let endedAt: Date
        public let reason: String
    }

    private let service: InferenceService

    /// The system prompt a fresh launch starts with. It demonstrates the task
    /// this model is good at — turning prose into a fixed schema — and works
    /// on the first message.
    ///
    /// The "explicitly says" rule keeps qualifiers out of "dislikes": with the
    /// rule, "likes eggs, but only scrambled" yields `{"likes":["scrambled
    /// eggs"]}`; without it, "eggs" lands in the dislikes. The plain key names
    /// are deliberate — this model reads "dislikes" literally and
    /// "negative_attribute" loosely.
    public static let defaultInstructions = """
        You extract what the user likes and dislikes. Answer only in JSON: \
        {"likes":[...],"dislikes":[...]}. Only put an item in "dislikes" if the \
        user explicitly says they don't like it; use [] when empty.
        """

    public private(set) var sessionId: String?
    /// Edited freely; only reaches the model when applied. A session fixes its
    /// instructions at construction, so applying necessarily starts a new one —
    /// the UI says so rather than hiding it.
    public var instructionsDraft: String = ChatModel.defaultInstructions
    public private(set) var appliedInstructions: String? = ChatModel.defaultInstructions
    public private(set) var messages: [Message] = []
    public private(set) var retired: [RetiredSession] = []
    public private(set) var usage: ContextUsage?
    public private(set) var status: StatusResponse?
    public private(set) var isSending = false

    public init(service: InferenceService = InferenceService()) {
        self.service = service
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
        status = await service.status()
        if sessionId == nil {
            sessionId = await service.createSession(instructions: appliedInstructions)
            await refreshUsage()
        }
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
            let response = try await service.generateResponse(for: prompt, sessionId: sessionId)
            messages.append(Message(kind: .model, text: response.response))
        } catch let error as InferenceError {
            if case .contextSizeExceeded(let used, let limit) = error {
                messages.append(Message(
                    kind: .failure,
                    text: error.reason,
                    exhaustion: ContextExhaustion(used: used, limit: limit)
                ))
            } else {
                messages.append(Message(kind: .failure, text: error.reason))
            }
        } catch {
            messages.append(Message(kind: .failure, text: "\(error)"))
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
        self.sessionId = await service.createSession(instructions: instructions)
        await refreshUsage()
    }

    /// The current session as plain text. Model and system prompt lead, so
    /// the transcript carries what is needed to reproduce it.
    public var transcriptText: String {
        var lines: [String] = []
        lines.append("Model: \(status?.variant ?? "unknown")")
        lines.append("System prompt: \(appliedInstructions ?? "none")")
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

    public func refreshUsage() async {
        guard let sessionId else { return }
        usage = try? await service.contextUsage(sessionId: sessionId)
    }
}
