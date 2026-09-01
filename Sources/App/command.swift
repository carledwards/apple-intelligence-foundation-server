import Vapor
import Foundation
import FoundationModels
import CoreGraphics
import ImageIO
import CryptoKit

// MARK: - Arbitrary JSON

/// Holds caller-supplied `metadata` verbatim. The server never interprets it and
/// never shows it to the model — it exists so log records carry the context that
/// explains why a request was made.
enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Request/Response Models

/// A single image supplied alongside a prompt. `data` is base64-encoded bytes of
/// any format ImageIO can read (PNG, JPEG, HEIC, …); a `data:` URL prefix is
/// tolerated so browser-produced payloads work as-is.
struct ImageInput: Content {
    let data: String
    let label: String?
}

struct InferenceRequest: Content {
    let prompt: String
    let sessionId: String?
    /// Create a fresh persisted session for this request and return its id,
    /// without a separate `POST /sessions` round trip. Conflicts with `sessionId`.
    let newSession: Bool?
    /// Clear the transcript of `sessionId` before responding, freeing its context
    /// budget while keeping the id stable. Requires `sessionId`.
    let reset: Bool?
    let images: [ImageInput]?
    /// Free-form context recorded in the log and never sent to the model.
    let metadata: JSONValue?

    enum CodingKeys: String, CodingKey {
        case prompt
        case sessionId = "session_id"
        case newSession = "new_session"
        case reset
        case images
        case metadata
    }
}

struct InferenceResponse: Content {
    let response: String
    /// The session this response was generated in, or nil for a one-shot request
    /// that was not persisted.
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case response
        case sessionId = "session_id"
    }
}

struct StatusResponse: Content {
    let available: Bool
    let message: String
    /// Display name of the on-device model variant, e.g. "AFM 3 Core Advanced".
    /// Nil on macOS 26, which has no way to report the variant.
    let variant: String?
    let contextSize: Int
    let supportsVision: Bool
    let supportsGuidedGeneration: Bool
    let supportsReasoning: Bool

    enum CodingKeys: String, CodingKey {
        case available
        case message
        case variant
        case contextSize = "context_size"
        case supportsVision = "supports_vision"
        case supportsGuidedGeneration = "supports_guided_generation"
        case supportsReasoning = "supports_reasoning"
    }
}

struct ClassifyRequest: Content {
    /// The closed set of labels the model must choose from. Include "none" or
    /// "other" — a constrained schema forces a pick, so without an escape hatch
    /// an unlisted subject is reported as whichever listed label fits worst.
    let classes: [String]
    let images: [ImageInput]
    /// Optional framing, e.g. "night-vision frame from a driveway camera".
    let hint: String?
    /// Run the classification this many times and report how often each label
    /// came up. Grounded, unlike a model's self-reported confidence.
    let samples: Int?
    /// Most labels a single sample may return, 1–10 (default 5). Set to 1 to
    /// force a single best label instead of everything visible.
    let maxLabels: Int?
    let metadata: JSONValue?

    enum CodingKeys: String, CodingKey {
        case classes
        case images
        case hint
        case samples
        case maxLabels = "max_labels"
        case metadata
    }
}

/// One label the model reported, with how consistently it did so.
struct ClassifiedSubject: Content {
    let label: String
    let votes: Int
    /// Fraction of samples that included this label, 0.0–1.0. Numeric so callers
    /// can threshold directly (`agreement >= 0.67`) without parsing.
    let agreement: Double
}

struct ClassifyResponse: Content {
    /// Every label seen, most consistent first. A scene with a person walking a
    /// dog returns both — the model is not forced to pick one.
    let subjects: [ClassifiedSubject]
    let sampleCount: Int
    /// The raw label set from each sample, in order.
    let samples: [[String]]
    let durationMs: Int

    enum CodingKeys: String, CodingKey {
        case subjects
        case sampleCount = "sample_count"
        case samples
        case durationMs = "duration_ms"
    }
}

struct CreateSessionResponse: Content {
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
    }
}

struct DeleteSessionResponse: Content {
    let message: String
}

struct ErrorResponse: Content {
    let error: String
}

// MARK: - Inference Log

/// Identifies an image without storing it. The digest is enough to correlate a
/// log line back to the source frame and to spot repeated frames.
struct ImageDigest: Encodable, Sendable {
    let sha256: String
    let bytes: Int
    let width: Int
    let height: Int
}

struct LogRecord: Encodable, Sendable {
    let ts: String
    let endpoint: String
    let sessionId: String?
    let prompt: String?
    let response: String?
    let classes: [String]?
    let images: [ImageDigest]
    let durationMs: Int
    let modelVariant: String?
    let metadata: JSONValue?
    let status: Int
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ts
        case endpoint
        case sessionId = "session_id"
        case prompt
        case response
        case classes
        case images
        case durationMs = "duration_ms"
        case modelVariant = "model_variant"
        case metadata
        case status
        case error
    }

    /// Written explicitly rather than synthesized so every record carries every
    /// key, with `null` where a value is absent. Synthesis uses `encodeIfPresent`,
    /// which drops keys and leaves the log ragged — awkward for `jq` and for
    /// anything that loads it as a table.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(response, forKey: .response)
        try container.encode(classes, forKey: .classes)
        try container.encode(images, forKey: .images)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(modelVariant, forKey: .modelVariant)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(status, forKey: .status)
        try container.encode(error, forKey: .error)
    }
}

/// Appends one JSON object per request to a file. Enabled by setting `LOG_FILE`;
/// when unset the server does not log prompts or responses at all.
actor InferenceLog {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw Abort(.internalServerError, reason: "Could not create log file at \(path)")
            }
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    static func timestamp() -> String {
        formatter.string(from: Date())
    }

    func write(_ record: LogRecord) {
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A) // newline
        try? handle.write(contentsOf: data)
    }

    func close() {
        try? handle.close()
    }
}

// MARK: - Error Middleware

struct JSONErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let abort as AbortError {
            let payload = ErrorResponse(error: abort.reason)
            let response = Response(status: abort.status)
            try response.content.encode(payload)
            return response
        } catch {
            request.logger.error("Unhandled error: \(error)")
            let payload = ErrorResponse(error: "\(error)")
            let response = Response(status: .internalServerError)
            try response.content.encode(payload)
            return response
        }
    }
}

// MARK: - Inference Service

actor InferenceService {
    private let model: SystemLanguageModel
    private var sessions: [String: LanguageModelSession] = [:]
    private var lastAccessed: [String: Date] = [:]
    /// Sessions with a `respond` call in flight. This actor's isolation is
    /// released across the `await` on the model, so two overlapping requests
    /// would otherwise both reach the same session — which `LanguageModelSession`
    /// rejects as a programmer error.
    private var busySessions: Set<String> = []
    private let log: InferenceLog?

    init(log: InferenceLog?) {
        self.model = SystemLanguageModel.default
        self.log = log
    }

    private var variantName: String? {
        if #available(macOS 27.0, *) { return model.variant.displayName }
        return nil
    }

    /// Records one request. `status` is the HTTP status the caller saw, so failures
    /// are as visible in the log as successes.
    private func record(
        endpoint: String,
        sessionId: String?,
        prompt: String?,
        response: String?,
        classes: [String]? = nil,
        images: [ImageDigest],
        started: Date,
        metadata: JSONValue?,
        status: Int,
        error: String? = nil
    ) async {
        guard let log else { return }
        await log.write(LogRecord(
            ts: InferenceLog.timestamp(),
            endpoint: endpoint,
            sessionId: sessionId,
            prompt: prompt,
            response: response,
            classes: classes,
            images: images,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            modelVariant: variantName,
            metadata: metadata,
            status: status,
            error: error
        ))
    }

    func checkAvailability() -> Bool {
        switch model.availability {
        case .available:
            return true
        default:
            return false
        }
    }

    /// Describes the model actually backing this server. The variant and
    /// capability flags only exist on macOS 27+; `contextSize` back-deploys to a
    /// fixed 4096 on macOS 26 and reports the real size from macOS 27 on.
    func status() -> StatusResponse {
        var variant: String?
        var supportsVision = false
        var supportsGuidedGeneration = false
        var supportsReasoning = false

        if #available(macOS 27.0, *) {
            variant = model.variant.displayName
            supportsVision = model.capabilities.contains(.vision)
            supportsGuidedGeneration = model.capabilities.contains(.guidedGeneration)
            supportsReasoning = model.capabilities.contains(.reasoning)
        }

        return StatusResponse(
            available: checkAvailability(),
            message: getAvailabilityMessage(),
            variant: variant,
            contextSize: model.contextSize,
            supportsVision: supportsVision,
            supportsGuidedGeneration: supportsGuidedGeneration,
            supportsReasoning: supportsReasoning
        )
    }

    func getAvailabilityMessage() -> String {
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
    }

    private func makeSession() -> (id: String, session: LanguageModelSession) {
        let id = UUID().uuidString
        let session = LanguageModelSession()
        sessions[id] = session
        lastAccessed[id] = Date()
        return (id, session)
    }

    func createSession() -> String {
        makeSession().id
    }

    func deleteSession(_ id: String) {
        sessions.removeValue(forKey: id)
        lastAccessed.removeValue(forKey: id)
    }

    func cleanupStaleSessions() {
        let cutoff = Date().addingTimeInterval(-30 * 60) // 30 minutes
        let staleIds = lastAccessed.filter { $0.value < cutoff }.map { $0.key }
        for id in staleIds {
            sessions.removeValue(forKey: id)
            lastAccessed.removeValue(forKey: id)
        }
    }

    func generateResponse(
        for prompt: String,
        sessionId: String? = nil,
        newSession: Bool = false,
        reset: Bool = false,
        images: [ImageInput] = [],
        metadata: JSONValue? = nil
    ) async throws -> InferenceResponse {
        let started = Date()
        var digests: [ImageDigest] = []
        do {
            let response = try await runInference(
                prompt: prompt, sessionId: sessionId, newSession: newSession,
                reset: reset, images: images, digests: &digests
            )
            await record(endpoint: "/inference", sessionId: response.sessionId, prompt: prompt,
                         response: response.response, images: digests, started: started,
                         metadata: metadata, status: 200)
            return response
        } catch {
            let status = (error as? AbortError)?.status.code ?? 500
            let reason = (error as? AbortError)?.reason ?? "\(error)"
            await record(endpoint: "/inference", sessionId: sessionId, prompt: prompt,
                         response: nil, images: digests, started: started,
                         metadata: metadata, status: Int(status), error: reason)
            throw error
        }
    }

    private func runInference(
        prompt: String,
        sessionId: String?,
        newSession: Bool,
        reset: Bool,
        images: [ImageInput],
        digests: inout [ImageDigest]
    ) async throws -> InferenceResponse {
        guard checkAvailability() else {
            throw Abort(.serviceUnavailable, reason: getAvailabilityMessage())
        }
        guard !(newSession && sessionId != nil) else {
            throw Abort(.badRequest, reason: "Pass either session_id or new_session, not both. To clear an existing session, use reset")
        }
        guard !(reset && sessionId == nil) else {
            throw Abort(.badRequest, reason: "reset requires session_id. To start a fresh session, use new_session")
        }

        let session: LanguageModelSession
        let resolvedSessionId: String?

        if let sessionId {
            guard let existing = sessions[sessionId] else {
                throw Abort(.notFound, reason: "Session not found: \(sessionId)")
            }
            // Checked before `reset` so an in-flight response is never swapped
            // out from under the model.
            guard !busySessions.contains(sessionId) else {
                throw Abort(.conflict, reason: "Session \(sessionId) is already handling a request. Requests sharing a session must be sequential")
            }
            if reset {
                // Replace the session in place so the caller keeps its id while
                // the transcript, and the context budget it consumed, are dropped.
                let fresh = LanguageModelSession()
                sessions[sessionId] = fresh
                session = fresh
            } else {
                session = existing
            }
            lastAccessed[sessionId] = Date()
            resolvedSessionId = sessionId
        } else if newSession {
            let created = makeSession()
            session = created.session
            resolvedSessionId = created.id
        } else {
            // One-shot request: the session is discarded once the response returns.
            session = LanguageModelSession()
            resolvedSessionId = nil
        }

        // A one-shot request owns its session outright, so only shared sessions
        // need marking. `defer` releases the mark on the error paths too.
        guard let busyId = resolvedSessionId else {
            let content = try await respond(in: session, to: prompt, images: images, digests: &digests)
            return InferenceResponse(response: content, sessionId: nil)
        }
        busySessions.insert(busyId)
        defer { busySessions.remove(busyId) }
        let content = try await respond(in: session, to: prompt, images: images, digests: &digests)
        return InferenceResponse(response: content, sessionId: busyId)
    }

    private func respond(
        in session: LanguageModelSession,
        to prompt: String,
        images: [ImageInput],
        digests: inout [ImageDigest]
    ) async throws -> String {
        guard !images.isEmpty else {
            return try await session.respond(to: prompt).content
        }

        guard #available(macOS 27.0, *) else {
            throw Abort(.badRequest, reason: "Image input requires macOS 27.0 or later")
        }
        guard model.capabilities.contains(.vision) else {
            throw Abort(.badRequest, reason: "The current model variant does not accept image input")
        }

        // Attachments carry a label so the prompt can refer to a specific image
        // when several are sent together.
        let decoded = try images.enumerated().map { index, image in
            (result: try Self.decodeImage(image, at: index), label: image.label ?? "image \(index + 1)")
        }
        digests = decoded.map(\.result.digest)
        let attachments = decoded.map { Attachment($0.result.image).label($0.label) }

        let response = try await session.respond {
            prompt
            attachments
        }
        return response.content
    }

    // MARK: Classification

    func classify(_ request: ClassifyRequest) async throws -> ClassifyResponse {
        let started = Date()
        var digests: [ImageDigest] = []
        do {
            let response = try await runClassify(request, started: started, digests: &digests)
            await record(endpoint: "/classify", sessionId: nil, prompt: request.hint,
                         response: response.subjects.map(\.label).joined(separator: ","),
                         classes: request.classes, images: digests,
                         started: started, metadata: request.metadata, status: 200)
            return response
        } catch {
            let status = (error as? AbortError)?.status.code ?? 500
            let reason = (error as? AbortError)?.reason ?? "\(error)"
            await record(endpoint: "/classify", sessionId: nil, prompt: request.hint,
                         response: nil, classes: request.classes, images: digests,
                         started: started, metadata: request.metadata, status: Int(status), error: reason)
            throw error
        }
    }

    private func runClassify(_ request: ClassifyRequest, started: Date, digests: inout [ImageDigest]) async throws -> ClassifyResponse {
        guard checkAvailability() else {
            throw Abort(.serviceUnavailable, reason: getAvailabilityMessage())
        }
        guard request.classes.count >= 2 else {
            throw Abort(.badRequest, reason: "classes must contain at least 2 labels")
        }
        guard request.classes.count <= 64 else {
            throw Abort(.badRequest, reason: "classes must contain at most 64 labels")
        }
        guard Set(request.classes).count == request.classes.count else {
            throw Abort(.badRequest, reason: "classes must not contain duplicates")
        }
        guard !request.classes.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw Abort(.badRequest, reason: "classes must not contain empty labels")
        }
        guard !request.images.isEmpty else {
            throw Abort(.badRequest, reason: "classify requires at least one image")
        }
        let samples = request.samples ?? 1
        guard (1...9).contains(samples) else {
            throw Abort(.badRequest, reason: "samples must be between 1 and 9")
        }
        let maxLabels = request.maxLabels ?? 5
        guard (1...10).contains(maxLabels) else {
            throw Abort(.badRequest, reason: "max_labels must be between 1 and 10")
        }
        guard #available(macOS 27.0, *) else {
            throw Abort(.badRequest, reason: "Image input requires macOS 27.0 or later")
        }
        guard model.capabilities.contains(.vision) else {
            throw Abort(.badRequest, reason: "The current model variant does not accept image input")
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
            throw Abort(.badRequest, reason: "Could not build a schema from classes: \(error)")
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
            let session = LanguageModelSession(model: model)
            let result = try await session.respond(schema: schema) {
                instruction
                attachments
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
            throw Abort(.internalServerError, reason: "Classification produced no result")
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

    private static func decodeImage(_ image: ImageInput, at index: Int) throws -> (image: CGImage, digest: ImageDigest) {
        // Accept a bare base64 string or a full `data:image/png;base64,...` URL.
        var encoded = image.data
        if encoded.hasPrefix("data:"), let comma = encoded.firstIndex(of: ",") {
            encoded = String(encoded[encoded.index(after: comma)...])
        }

        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw Abort(.badRequest, reason: "images[\(index)].data is not valid base64")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Abort(.badRequest, reason: "images[\(index)].data is not a readable image format")
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

// MARK: - Application Setup

@main
struct App {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let logger = Logger(label: "App")
        let app = try await Application.make(env, .singleton, logger: logger)

        do {
            // Limits — generous enough for base64-encoded images, which inflate
            // the payload by roughly 4/3 over the raw bytes.
            app.routes.defaultMaxBodySize = "32mb"

            // Middleware
            app.middleware.use(JSONErrorMiddleware())

            // Request logging is opt-in: without LOG_FILE the server never writes
            // prompts, responses, or metadata anywhere.
            var inferenceLog: InferenceLog?
            if let path = Environment.get("LOG_FILE"), !path.isEmpty {
                inferenceLog = try InferenceLog(path: path)
                app.logger.info("Logging inference records to \(path)")
            }

            // Initialize inference service
            let inferenceService = InferenceService(log: inferenceLog)

            // Background cleanup task — runs every 5 minutes
            let cleanupTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    await inferenceService.cleanupStaleSessions()
                }
            }

            // Configure routes
            app.post("inference") { req async throws -> InferenceResponse in
                let request = try req.content.decode(InferenceRequest.self)
                return try await inferenceService.generateResponse(
                    for: request.prompt,
                    sessionId: request.sessionId,
                    newSession: request.newSession ?? false,
                    reset: request.reset ?? false,
                    images: request.images ?? [],
                    metadata: request.metadata
                )
            }

            // Closed-set image classification
            app.post("classify") { req async throws -> ClassifyResponse in
                try await inferenceService.classify(req.content.decode(ClassifyRequest.self))
            }

            // Session management
            app.post("sessions") { _ async -> CreateSessionResponse in
                let id = await inferenceService.createSession()
                return CreateSessionResponse(sessionId: id)
            }

            app.delete("sessions", ":sessionId") { req async throws -> DeleteSessionResponse in
                guard let sessionId = req.parameters.get("sessionId") else {
                    throw Abort(.badRequest, reason: "Missing session ID")
                }
                await inferenceService.deleteSession(sessionId)
                return DeleteSessionResponse(message: "Session deleted")
            }

            // Health check endpoint
            app.get("health") { _ in
                ["status": "ok"]
            }

            // Model status endpoint
            app.get("status") { _ async -> StatusResponse in
                await inferenceService.status()
            }

            app.logger.info("Server starting on http://localhost:8080")
            app.logger.info("Try: curl -X POST http://localhost:8080/inference -H \"Content-Type: application/json\" -d '{\"prompt\":\"Hello\"}'")

            try await app.execute()
            cleanupTask.cancel()
        } catch {
            app.logger.error("Application error: \(error)")
            try await app.asyncShutdown()
            throw error
        }

        try await app.asyncShutdown()
    }
}
