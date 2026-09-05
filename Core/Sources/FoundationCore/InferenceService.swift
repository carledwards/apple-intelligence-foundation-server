import Foundation
import FoundationModels
import CoreGraphics
import ImageIO
import CryptoKit

/// The model layer: sessions, image prompting, and closed-set classification.
///
/// Targets macOS 27 / iOS 27. Two models are reachable, `SystemLanguageModel`
/// on the device and `PrivateCloudComputeLanguageModel` on Apple's servers, and
/// every request names the one it wants; the default is on-device. Nothing
/// falls back to the cloud on its own — a silent fallback would mask exactly
/// the local failures this is built to find.
public actor InferenceService {
    private let model: SystemLanguageModel
    private let cloud: PrivateCloudComputeLanguageModel
    private var sessions: [String: LanguageModelSession] = [:]
    private var lastAccessed: [String: Date] = [:]
    /// Sessions with a `respond` call in flight. This actor's isolation is
    /// released across the `await` on the model, so two overlapping requests
    /// would otherwise both reach the same session — which `LanguageModelSession`
    /// rejects as a programmer error.
    private var busySessions: Set<String> = []
    /// Instructions each session was created with. `LanguageModelSession` fixes
    /// them at construction, so they are kept here to be reapplied when a session
    /// is reset — a reset clears the transcript, not the session's configuration.
    private var sessionInstructions: [String: String] = [:]
    /// The model each session was created on. Fixed for the session's life.
    private var sessionModel: [String: ModelChoice] = [:]
    private let log: InferenceLog?

    public init(log: InferenceLog? = nil) {
        self.model = SystemLanguageModel.default
        self.cloud = PrivateCloudComputeLanguageModel()
        self.log = log
    }

    // MARK: Backends

    /// The two model classes share `LanguageModel` but report availability,
    /// context size, and variant through different APIs. This is the one place
    /// that difference is handled.
    private enum Backend {
        case onDevice(SystemLanguageModel)
        case privateCloud(PrivateCloudComputeLanguageModel)

        var isAvailable: Bool {
            switch self {
            case .onDevice(let model):
                if case .available = model.availability { return true }
                return false
            case .privateCloud(let model):
                // The framework reports the service; the entitlement is the
                // caller's side of the bargain, and without it a request
                // traps rather than throws.
                return ProcessEntitlements.hasPrivateCloudCompute && model.isAvailable
            }
        }

        var availabilityMessage: String {
            switch self {
            case .onDevice(let model):
                switch model.availability {
                case .available:
                    return "Model is available"
                case .unavailable(.deviceNotEligible):
                    return "Device is not eligible for Apple Intelligence"
                case .unavailable(.appleIntelligenceNotEnabled):
                    return "Apple Intelligence is not enabled in Settings"
                case .unavailable(.modelNotReady):
                    return "Model is downloading or not ready yet"
                case .unavailable:
                    return "Model is unavailable for unknown reason"
                @unknown default:
                    return "Model availability unknown"
                }
            case .privateCloud(let model):
                guard ProcessEntitlements.hasPrivateCloudCompute else {
                    return "Private Cloud Compute requires the \(ProcessEntitlements.privateCloudComputeKey) entitlement, which this process does not have"
                }
                switch model.availability {
                case .available:
                    return "Private Cloud Compute is available"
                case .unavailable(.deviceNotEligible):
                    return "Device is not eligible for Private Cloud Compute"
                case .unavailable(.systemNotReady):
                    return "Private Cloud Compute is not ready"
                case .unavailable:
                    return "Private Cloud Compute is unavailable for unknown reason"
                @unknown default:
                    return "Private Cloud Compute availability unknown"
                }
            }
        }

        var capabilities: LanguageModelCapabilities {
            switch self {
            case .onDevice(let model): return model.capabilities
            case .privateCloud(let model): return model.capabilities
            }
        }

        /// The on-device variant name, or the service name for the cloud,
        /// which does not disclose one.
        var variantName: String {
            switch self {
            case .onDevice(let model): return model.variant.displayName
            case .privateCloud: return "Private Cloud Compute"
            }
        }

        /// The cloud reports its window over the network, so this is async.
        /// Zero when the cloud cannot be asked.
        func contextSize() async -> Int {
            switch self {
            case .onDevice(let model): return model.contextSize
            case .privateCloud(let model): return (try? await model.contextSize) ?? 0
            }
        }

        /// Instructions are the model's system channel: set once, applied to
        /// every turn, and charged to the context budget once.
        func makeSession(instructions: String?) -> LanguageModelSession {
            switch self {
            case .onDevice(let model):
                guard let instructions, !instructions.isEmpty else { return LanguageModelSession(model: model) }
                return LanguageModelSession(model: model, instructions: instructions)
            case .privateCloud(let model):
                guard let instructions, !instructions.isEmpty else { return LanguageModelSession(model: model) }
                return LanguageModelSession(model: model, instructions: instructions)
            }
        }
    }

    private func backend(_ choice: ModelChoice) -> Backend {
        switch choice {
        case .onDevice: return .onDevice(model)
        case .privateCloud: return .privateCloud(cloud)
        }
    }

    /// Records one request. `status` is the status the caller saw, so failures
    /// are as visible in the log as successes.
    private func record(
        endpoint: String,
        sessionId: String?,
        instructions: String? = nil,
        prompt: String?,
        response: String?,
        classes: [String]? = nil,
        images: [ImageDigest],
        started: Date,
        metadata: JSONValue?,
        model: ModelChoice = .onDevice,
        status: Int,
        error: String? = nil
    ) async {
        guard let log else { return }
        await log.write(LogRecord(
            ts: InferenceLog.timestamp(),
            endpoint: endpoint,
            sessionId: sessionId,
            instructions: instructions,
            prompt: prompt,
            response: response,
            classes: classes,
            images: images,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            modelVariant: backend(model).variantName,
            metadata: metadata,
            status: status,
            error: error
        ))
    }

    public func checkAvailability(model: ModelChoice = .onDevice) -> Bool {
        backend(model).isAvailable
    }

    /// Describes one of the models backing this process — variant, context
    /// budget, and which capabilities it reports.
    public func status(model choice: ModelChoice = .onDevice) async -> StatusResponse {
        let backend = backend(choice)
        return StatusResponse(
            model: choice,
            available: backend.isAvailable,
            message: backend.availabilityMessage,
            variant: backend.variantName,
            contextSize: await backend.contextSize(),
            supportsVision: backend.capabilities.contains(.vision),
            supportsGuidedGeneration: backend.capabilities.contains(.guidedGeneration),
            supportsReasoning: backend.capabilities.contains(.reasoning)
        )
    }

    public func getAvailabilityMessage(model: ModelChoice = .onDevice) -> String {
        backend(model).availabilityMessage
    }

    private func makeSession(instructions: String?, model: ModelChoice) -> (id: String, session: LanguageModelSession) {
        let id = UUID().uuidString
        let session = backend(model).makeSession(instructions: instructions)
        sessions[id] = session
        lastAccessed[id] = Date()
        sessionModel[id] = model
        if let instructions, !instructions.isEmpty {
            sessionInstructions[id] = instructions
        }
        return (id, session)
    }

    public func createSession(instructions: String? = nil, model: ModelChoice = .onDevice) -> String {
        makeSession(instructions: instructions, model: model).id
    }

    /// What a session was created with, so a UI can show the system channel
    /// that is steering every answer without having to track it separately.
    public func instructions(for sessionId: String) -> String? {
        sessionInstructions[sessionId]
    }

    /// The model a session runs on, or nil for an unknown session.
    public func model(for sessionId: String) -> ModelChoice? {
        sessionModel[sessionId]
    }

    public func deleteSession(_ id: String) {
        sessions.removeValue(forKey: id)
        lastAccessed.removeValue(forKey: id)
        sessionInstructions.removeValue(forKey: id)
        sessionModel.removeValue(forKey: id)
    }

    public func cleanupStaleSessions() {
        let cutoff = Date().addingTimeInterval(-30 * 60) // 30 minutes
        let staleIds = lastAccessed.filter { $0.value < cutoff }.map { $0.key }
        for id in staleIds {
            deleteSession(id)
        }
    }

    // MARK: Context accounting

    /// How much of the context window a session has consumed so far.
    ///
    /// The count is measured over the session's real transcript rather than
    /// estimated from message or character counts, so it stays correct as
    /// images, instructions, and tool definitions are added.
    public func contextUsage(sessionId: String) async throws -> ContextUsage {
        guard let session = sessions[sessionId] else {
            throw InferenceError.sessionNotFound(sessionId)
        }
        // The cloud model has no token counter; its window is the only number.
        if sessionModel[sessionId] == .privateCloud {
            return ContextUsage(
                used: nil,
                limit: await backend(.privateCloud).contextSize(),
                note: "Token counting is not available for Private Cloud Compute sessions"
            )
        }
        do {
            let used = try await model.tokenCount(for: session.transcript)
            return ContextUsage(used: used, limit: model.contextSize)
        } catch {
            // Measured on macOS 27.0: counting throws ModelManagerError 1001 once
            // the transcript holds an image, while inference on the same session
            // continues to work. An unmeasurable session is a normal state to
            // display, not a request failure, so this reports rather than throws.
            return ContextUsage(
                used: nil,
                limit: model.contextSize,
                note: "Token counting unavailable for this session (\(error.localizedDescription))"
            )
        }
    }

    /// What a prompt would cost before sending it.
    ///
    /// Text only. The framework cannot count image attachments — passing one to
    /// `tokenCount(for:)` fails the same way an image-bearing transcript does —
    /// so images are rejected here with an explanation instead of an opaque error.
    public func tokenCount(for prompt: String, images: [ImageInput] = []) async throws -> Int {
        guard images.isEmpty else {
            throw InferenceError.invalidRequest(
                "Token counting does not support images. The model cannot count image attachments; send a text-only prompt"
            )
        }
        return try await model.tokenCount(for: Prompt(prompt))
    }

    public func generateResponse(
        for prompt: String,
        sessionId: String? = nil,
        newSession: Bool = false,
        reset: Bool = false,
        images: [ImageInput] = [],
        instructions: String? = nil,
        model: ModelChoice? = nil,
        schema: OutputSchema? = nil,
        metadata: JSONValue? = nil
    ) async throws -> InferenceResponse {
        let started = Date()
        var digests: [ImageDigest] = []
        // A continuing session answers on the model it was created with.
        let resolvedModel = sessionId.flatMap { sessionModel[$0] } ?? model ?? .onDevice
        do {
            let response = try await runInference(
                prompt: prompt, sessionId: sessionId, newSession: newSession,
                reset: reset, images: images, instructions: instructions,
                model: model, resolvedModel: resolvedModel, schema: schema, digests: &digests
            )
            // Resolve from the session so a continuing turn logs the instructions
            // already in force, not just the ones passed on this call.
            let inForce = response.sessionId.flatMap { sessionInstructions[$0] } ?? instructions
            await record(endpoint: "/inference", sessionId: response.sessionId,
                         instructions: inForce, prompt: prompt,
                         response: response.response, images: digests, started: started,
                         metadata: metadata, model: resolvedModel, status: 200)
            return response
        } catch {
            await record(endpoint: "/inference", sessionId: sessionId,
                         instructions: sessionId.flatMap { sessionInstructions[$0] } ?? instructions,
                         prompt: prompt,
                         response: nil, images: digests, started: started,
                         metadata: metadata, model: resolvedModel, status: Self.status(of: error),
                         error: Self.reason(of: error))
            throw error
        }
    }

    private func runInference(
        prompt: String,
        sessionId: String?,
        newSession: Bool,
        reset: Bool,
        images: [ImageInput],
        instructions: String?,
        model requestedModel: ModelChoice?,
        resolvedModel: ModelChoice,
        schema: OutputSchema?,
        digests: inout [ImageDigest]
    ) async throws -> InferenceResponse {
        let backend = backend(resolvedModel)
        guard backend.isAvailable else {
            throw InferenceError.modelUnavailable(backend.availabilityMessage)
        }
        // Checked before any session is created, so a bad schema cannot leave a
        // new persisted session behind.
        let generation = try schema?.generationSchema()
        // A session's model is fixed at creation, like its instructions. A
        // request naming a different one is refused, not silently redirected.
        if let requestedModel, let sessionId, let bound = sessionModel[sessionId], bound != requestedModel {
            throw InferenceError.invalidRequest(
                "Session \(sessionId) runs on \(bound.rawValue); model cannot be changed on an existing session. Start a new one"
            )
        }
        guard !(newSession && sessionId != nil) else {
            throw InferenceError.invalidRequest("Pass either session_id or new_session, not both. To clear an existing session, use reset")
        }
        guard !(reset && sessionId == nil) else {
            throw InferenceError.invalidRequest("reset requires session_id. To start a fresh session, use new_session")
        }
        // A session's instructions are fixed when it is constructed, so they
        // cannot be changed on an existing one. Saying so is better than
        // accepting the field and silently ignoring it.
        if instructions != nil, sessionId != nil {
            throw InferenceError.invalidRequest(
                "instructions can only be set when a session is created. Use new_session, or delete this session and make a new one"
            )
        }

        let session: LanguageModelSession
        let resolvedSessionId: String?

        if let sessionId {
            guard let existing = sessions[sessionId] else {
                throw InferenceError.sessionNotFound(sessionId)
            }
            // Checked before `reset` so an in-flight response is never swapped
            // out from under the model.
            guard !busySessions.contains(sessionId) else {
                throw InferenceError.sessionBusy(sessionId)
            }
            if reset {
                // Replace the session in place so the caller keeps its id while
                // the transcript, and the context budget it consumed, are dropped.
                // The instructions it was created with are reapplied: a reset
                // clears the conversation, not the session's configuration.
                let fresh = backend.makeSession(instructions: sessionInstructions[sessionId])
                sessions[sessionId] = fresh
                session = fresh
            } else {
                session = existing
            }
            lastAccessed[sessionId] = Date()
            resolvedSessionId = sessionId
        } else if newSession {
            let created = makeSession(instructions: instructions, model: resolvedModel)
            session = created.session
            resolvedSessionId = created.id
        } else {
            // One-shot request: the session is discarded once the response returns.
            session = backend.makeSession(instructions: instructions)
            resolvedSessionId = nil
        }

        // A one-shot request owns its session outright, so only shared sessions
        // need marking. `defer` releases the mark on the error paths too.
        guard let busyId = resolvedSessionId else {
            let content = try await respond(
                in: session, on: backend, to: prompt, images: images, schema: generation, digests: &digests
            )
            return InferenceResponse(response: content, sessionId: nil)
        }
        busySessions.insert(busyId)
        defer { busySessions.remove(busyId) }
        let content = try await respond(
            in: session, on: backend, to: prompt, images: images, schema: generation, digests: &digests
        )
        return InferenceResponse(response: content, sessionId: busyId)
    }

    /// With a schema, the answer is the generated object as JSON text. The
    /// framework built the structure, so it is well-formed by construction.
    private func respond(
        in session: LanguageModelSession,
        on backend: Backend,
        to prompt: String,
        images: [ImageInput],
        schema: GenerationSchema?,
        digests: inout [ImageDigest]
    ) async throws -> String {
        var attachments: [Attachment<ImageAttachmentContent>] = []
        if !images.isEmpty {
            guard backend.capabilities.contains(.vision) else {
                throw InferenceError.visionUnsupported
            }
            // Attachments carry a label so the prompt can refer to a specific
            // image when several are sent together.
            let decoded = try images.enumerated().map { index, image in
                (result: try Self.decodeImage(image, at: index), label: image.label ?? "image \(index + 1)")
            }
            digests = decoded.map(\.result.digest)
            attachments = decoded.map { Attachment($0.result.image).label($0.label) }
        }

        do {
            if let schema {
                let result = try await session.respond(schema: schema) {
                    prompt
                    attachments
                }
                return OutputSchema.canonicalJSON(result.content.jsonString)
            }
            let response = try await session.respond {
                prompt
                attachments
            }
            return response.content
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: Sampling

    /// Runs the same free-form prompt several times and reports how consistent
    /// the answers were.
    ///
    /// Unlike `classify`, nothing constrains the output to a vocabulary — this is
    /// for probing what the model actually says. Each sample runs in its own
    /// session so the votes stay uncorrelated; reusing one session would let the
    /// first answer bias the rest, which measures the transcript rather than the
    /// prompt.
    public func sample(
        prompt: String,
        images: [ImageInput] = [],
        instructions: String? = nil,
        samples: Int = 3,
        choices: [String]? = nil,
        schema: OutputSchema? = nil,
        model: ModelChoice = .onDevice,
        metadata: JSONValue? = nil
    ) async throws -> SampleRun {
        let started = Date()
        var digests: [ImageDigest] = []
        do {
            let run = try await runSamples(
                prompt: prompt, images: images, instructions: instructions,
                samples: samples, choices: choices, schema: schema, model: model,
                started: started, digests: &digests
            )
            await record(endpoint: "/sample", sessionId: nil, instructions: instructions,
                         prompt: prompt,
                         response: run.answers.map { "\($0.text) (\($0.count)/\(run.sampleCount))" }
                             .joined(separator: " | "),
                         images: digests, started: started, metadata: metadata, model: model, status: 200)
            return run
        } catch {
            await record(endpoint: "/sample", sessionId: nil, instructions: instructions,
                         prompt: prompt, response: nil, images: digests, started: started,
                         metadata: metadata, model: model, status: Self.status(of: error),
                         error: Self.reason(of: error))
            throw error
        }
    }

    private func runSamples(
        prompt: String,
        images: [ImageInput],
        instructions: String?,
        samples: Int,
        choices: [String]?,
        schema: OutputSchema?,
        model: ModelChoice,
        started: Date,
        digests: inout [ImageDigest]
    ) async throws -> SampleRun {
        let backend = backend(model)
        guard backend.isAvailable else {
            throw InferenceError.modelUnavailable(backend.availabilityMessage)
        }
        guard choices == nil || schema == nil else {
            throw InferenceError.invalidRequest("Pass either choices or schema, not both")
        }
        let generation = try schema?.generationSchema()
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InferenceError.invalidRequest("prompt must not be empty")
        }
        guard (1...9).contains(samples) else {
            throw InferenceError.invalidRequest("samples must be between 1 and 9")
        }
        if let choices {
            guard choices.count >= 2 else {
                throw InferenceError.invalidRequest("choices must contain at least 2 options")
            }
            guard choices.count <= 64 else {
                throw InferenceError.invalidRequest("choices must contain at most 64 options")
            }
            guard Set(choices).count == choices.count else {
                throw InferenceError.invalidRequest("choices must not contain duplicates")
            }
            guard !choices.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw InferenceError.invalidRequest("choices must not contain empty options")
            }
        }
        if !images.isEmpty {
            guard backend.capabilities.contains(.vision) else {
                throw InferenceError.visionUnsupported
            }
        }

        // A closed answer set makes agreement mean something. Over free prose it
        // does not: six answers that all say "yes, there are animals" differ only
        // in wording, and counting distinct strings reports that as total
        // disagreement. Constraining the output is the honest way to measure
        // whether the model is consistent about the *answer*.
        let schema = try choices.map { try Self.choiceSchema(for: $0) }

        var responses: [String] = []
        for _ in 0..<samples {
            let session = backend.makeSession(instructions: instructions)
            var perRun: [ImageDigest] = []
            if let schema {
                responses.append(
                    try await respondWithChoices(
                        in: session, on: backend, to: prompt, images: images, schema: schema, digests: &perRun
                    )
                )
            } else {
                // With a schema each sample is the generated object as JSON;
                // agreement then compares whole objects, so it measures whether
                // the model is consistent about the values, not the wording.
                responses.append(
                    try await respond(in: session, on: backend, to: prompt, images: images, schema: generation, digests: &perRun)
                )
            }
            // Identical every round; recorded once rather than N times.
            if digests.isEmpty { digests = perRun }
        }

        // Group by normalized form, keeping first-seen order and raw text.
        var order: [String] = []
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for response in responses {
            let key = SampleRun.key(for: response)
            if counts[key] == nil {
                order.append(key)
                display[key] = response.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            counts[key, default: 0] += 1
        }

        // Most agreed first; ties keep the order the model produced them in, so
        // repeated runs of the same data render stably.
        let answers = order
            .sorted { lhs, rhs in
                let (l, r) = (counts[lhs] ?? 0, counts[rhs] ?? 0)
                if l != r { return l > r }
                return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
            }
            .map { key in
                SampledAnswer(
                    text: display[key] ?? key,
                    count: counts[key] ?? 0,
                    agreement: Double(counts[key] ?? 0) / Double(samples)
                )
            }

        return SampleRun(
            answers: answers,
            responses: responses,
            sampleCount: samples,
            durationMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    private static func choiceSchema(for choices: [String]) throws -> GenerationSchema {
        do {
            let choice = DynamicGenerationSchema(
                name: "answer",
                description: "The answer to the question",
                anyOf: choices
            )
            return try GenerationSchema(
                root: DynamicGenerationSchema(name: "Answer", properties: [
                    .init(name: "answer", schema: choice)
                ]),
                dependencies: []
            )
        } catch {
            throw InferenceError.schemaConstructionFailed("Could not build a schema from choices: \(error)")
        }
    }

    private func respondWithChoices(
        in session: LanguageModelSession,
        on backend: Backend,
        to prompt: String,
        images: [ImageInput],
        schema: GenerationSchema,
        digests: inout [ImageDigest]
    ) async throws -> String {
        let attachments: [Attachment<ImageAttachmentContent>]
        if images.isEmpty {
            attachments = []
        } else {
            guard backend.capabilities.contains(.vision) else {
                throw InferenceError.visionUnsupported
            }
            let decoded = try images.enumerated().map { index, image in
                (result: try Self.decodeImage(image, at: index), label: image.label ?? "image \(index + 1)")
            }
            digests = decoded.map(\.result.digest)
            attachments = decoded.map { Attachment($0.result.image).label($0.label) }
        }
        do {
            let result = try await session.respond(schema: schema) {
                prompt
                attachments
            }
            return try result.content.value(String.self, forProperty: "answer")
        } catch {
            throw Self.translate(error)
        }
    }

    // MARK: Classification

    public func classify(_ request: ClassifyRequest) async throws -> ClassifyResponse {
        let started = Date()
        var digests: [ImageDigest] = []
        do {
            let response = try await runClassify(request, started: started, digests: &digests)
            await record(endpoint: "/classify", sessionId: nil, prompt: request.hint,
                         response: response.subjects.map(\.label).joined(separator: ","),
                         classes: request.classes, images: digests,
                         started: started, metadata: request.metadata,
                         model: request.model ?? .onDevice, status: 200)
            return response
        } catch {
            await record(endpoint: "/classify", sessionId: nil, prompt: request.hint,
                         response: nil, classes: request.classes, images: digests,
                         started: started, metadata: request.metadata,
                         model: request.model ?? .onDevice,
                         status: Self.status(of: error), error: Self.reason(of: error))
            throw error
        }
    }

    private func runClassify(_ request: ClassifyRequest, started: Date, digests: inout [ImageDigest]) async throws -> ClassifyResponse {
        let backend = backend(request.model ?? .onDevice)
        guard backend.isAvailable else {
            throw InferenceError.modelUnavailable(backend.availabilityMessage)
        }
        guard request.classes.count >= 2 else {
            throw InferenceError.invalidRequest("classes must contain at least 2 labels")
        }
        guard request.classes.count <= 64 else {
            throw InferenceError.invalidRequest("classes must contain at most 64 labels")
        }
        guard Set(request.classes).count == request.classes.count else {
            throw InferenceError.invalidRequest("classes must not contain duplicates")
        }
        guard !request.classes.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw InferenceError.invalidRequest("classes must not contain empty labels")
        }
        guard !request.images.isEmpty else {
            throw InferenceError.invalidRequest("classify requires at least one image")
        }
        let samples = request.samples ?? 1
        guard (1...9).contains(samples) else {
            throw InferenceError.invalidRequest("samples must be between 1 and 9")
        }
        let maxLabels = request.maxLabels ?? 5
        guard (1...10).contains(maxLabels) else {
            throw InferenceError.invalidRequest("max_labels must be between 1 and 10")
        }
        guard backend.capabilities.contains(.vision) else {
            throw InferenceError.visionUnsupported
        }

        // A schema built from the caller's labels constrains the model to that
        // vocabulary — it cannot answer with anything outside the list. The array
        // lets a scene report everything in it rather than collapsing to one label.
        let schema: GenerationSchema
        do {
            let label = DynamicGenerationSchema(
                name: "label",
                description: "A label for something visible in the image",
                anyOf: request.classes
            )
            schema = try GenerationSchema(
                root: DynamicGenerationSchema(name: "Verdict", properties: [
                    .init(name: "subjects", schema: DynamicGenerationSchema(
                        arrayOf: label, minimumElements: 1, maximumElements: maxLabels
                    ))
                ]),
                dependencies: []
            )
        } catch {
            throw InferenceError.schemaConstructionFailed("Could not build a schema from classes: \(error)")
        }

        let decoded = try request.images.enumerated().map { index, image in
            (result: try Self.decodeImage(image, at: index), label: image.label ?? "frame \(index + 1)")
        }
        digests = decoded.map(\.result.digest)
        let attachments = decoded.map { Attachment($0.result.image).label($0.label) }

        var instruction = maxLabels == 1
            ? "What is in this image? Choose the single best label."
            : "List every distinct subject visible in this image. Include each label only once."
        if let hint = request.hint, !hint.isEmpty {
            instruction += " \(hint)"
        }

        // Each sample is an independent session so votes stay uncorrelated.
        var rounds: [[String]] = []
        for _ in 0..<samples {
            let session = backend.makeSession(instructions: nil)
            let result: LanguageModelSession.Response<GeneratedContent>
            do {
                result = try await session.respond(schema: schema) {
                    instruction
                    attachments
                }
            } catch {
                throw Self.translate(error)
            }
            // Deduplicate within a round so one sample cannot vote twice for the
            // same label, which would inflate its agreement past 1.0.
            var seen = Set<String>()
            rounds.append(try result.content.value([String].self, forProperty: "subjects")
                .filter { seen.insert($0).inserted })
        }

        var tally: [String: Int] = [:]
        for round in rounds {
            for label in round { tally[label, default: 0] += 1 }
        }
        guard !tally.isEmpty else {
            throw InferenceError.emptyClassification
        }

        // Most agreed-upon first; ties fall back to the caller's own ordering so
        // repeated runs return labels in a stable order.
        let subjects = tally.sorted {
            $0.value != $1.value
                ? $0.value > $1.value
                : (request.classes.firstIndex(of: $0.key) ?? .max) < (request.classes.firstIndex(of: $1.key) ?? .max)
        }.map {
            ClassifiedSubject(
                label: $0.key,
                votes: $0.value,
                agreement: Double($0.value) / Double(samples)
            )
        }

        return ClassifyResponse(
            subjects: subjects,
            sampleCount: samples,
            samples: rounds,
            durationMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    // MARK: Helpers

    /// Lifts the framework's own errors into `InferenceError` where this package
    /// has something more useful to say. Context exhaustion is the case that
    /// matters: it carries real numbers, and a caller that only sees a string has
    /// no way to show how far over the budget it went.
    private static func translate(_ error: Error) -> Error {
        if isMissingCloudEntitlement(error) {
            return InferenceError.modelUnavailable(
                "Private Cloud Compute refused this process (ModelManagerError 1046). It requires the com.apple.developer.private-cloud-compute entitlement, which a SwiftPM executable cannot carry; run the Xcode-built app"
            )
        }
        if let cloudError = error as? PrivateCloudComputeLanguageModel.Error {
            switch cloudError {
            case .quotaLimitReached:
                return InferenceError.quotaExceeded(cloudError.localizedDescription)
            case .networkFailure, .serviceUnavailable:
                return InferenceError.modelUnavailable(cloudError.localizedDescription)
            @unknown default:
                return error
            }
        }
        guard let modelError = error as? LanguageModelError else { return error }
        switch modelError {
        case .contextSizeExceeded(let info):
            return InferenceError.contextSizeExceeded(used: info.tokenCount, limit: info.contextSize)
        case .guardrailViolation, .refusal:
            return InferenceError.contentRefused(modelError.localizedDescription)
        case .rateLimited:
            return InferenceError.rateLimited
        case .timeout:
            return InferenceError.timedOut
        default:
            return error
        }
    }

    /// `ModelManagerError 1046`, nested under a generic `LanguageModelError`,
    /// is the cloud model's answer to a process without the
    /// `com.apple.developer.private-cloud-compute` entitlement. Measured: a
    /// signed app missing it traps with that entitlement named; the same
    /// build with it answers; an unsigned binary gets this error instead.
    private static func isMissingCloudEntitlement(_ error: Error) -> Bool {
        func walk(_ error: NSError) -> Bool {
            if error.domain == "ModelManagerServices.ModelManagerError", error.code == 1046 { return true }
            let nested = (error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError]) ?? []
            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { [$0] } ?? []
            return (nested + underlying).contains(where: walk)
        }
        return walk(error as NSError)
    }

    private static func status(of error: Error) -> Int {
        (error as? InferenceError)?.statusCode ?? 500
    }

    private static func reason(of error: Error) -> String {
        (error as? InferenceError)?.reason ?? "\(error)"
    }

    private static func decodeImage(_ image: ImageInput, at index: Int) throws -> (image: CGImage, digest: ImageDigest) {
        // Accept a bare base64 string or a full `data:image/png;base64,...` URL.
        var encoded = image.data
        if encoded.hasPrefix("data:"), let comma = encoded.firstIndex(of: ",") {
            encoded = String(encoded[encoded.index(after: comma)...])
        }

        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw InferenceError.imageDecodingFailed("images[\(index)].data is not valid base64")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw InferenceError.imageDecodingFailed("images[\(index)].data is not a readable image format")
        }

        let digest = ImageDigest(
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            bytes: data.count,
            width: decoded.width,
            height: decoded.height
        )
        return (decoded, digest)
    }
}
