import Foundation
import FoundationModels
import CoreGraphics
import ImageIO
import CryptoKit

/// The model layer: sessions, image prompting, and closed-set classification.
///
/// Targets macOS 27 / iOS 27 and uses `SystemLanguageModel.default` — the
/// on-device model only. Private Cloud Compute is deliberately not used, because
/// a cloud fallback would mask exactly the local failures this is built to find.
public actor InferenceService {
    private let model: SystemLanguageModel
    private var sessions: [String: LanguageModelSession] = [:]
    private var lastAccessed: [String: Date] = [:]
    /// Sessions with a `respond` call in flight. This actor's isolation is
    /// released across the `await` on the model, so two overlapping requests
    /// would otherwise both reach the same session — which `LanguageModelSession`
    /// rejects as a programmer error.
    private var busySessions: Set<String> = []
    private let log: InferenceLog?

    public init(log: InferenceLog? = nil) {
        self.model = SystemLanguageModel.default
        self.log = log
    }

    private var variantName: String {
        model.variant.displayName
    }

    /// Records one request. `status` is the status the caller saw, so failures
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

    public func checkAvailability() -> Bool {
        switch model.availability {
        case .available:
            return true
        default:
            return false
        }
    }

    /// Describes the model actually backing this process — variant, context
    /// budget, and which capabilities it reports.
    public func status() -> StatusResponse {
        StatusResponse(
            available: checkAvailability(),
            message: getAvailabilityMessage(),
            variant: model.variant.displayName,
            contextSize: model.contextSize,
            supportsVision: model.capabilities.contains(.vision),
            supportsGuidedGeneration: model.capabilities.contains(.guidedGeneration),
            supportsReasoning: model.capabilities.contains(.reasoning)
        )
    }

    public func getAvailabilityMessage() -> String {
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

    public func createSession() -> String {
        makeSession().id
    }

    public func deleteSession(_ id: String) {
        sessions.removeValue(forKey: id)
        lastAccessed.removeValue(forKey: id)
    }

    public func cleanupStaleSessions() {
        let cutoff = Date().addingTimeInterval(-30 * 60) // 30 minutes
        let staleIds = lastAccessed.filter { $0.value < cutoff }.map { $0.key }
        for id in staleIds {
            sessions.removeValue(forKey: id)
            lastAccessed.removeValue(forKey: id)
        }
    }

    public func generateResponse(
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
            await record(endpoint: "/inference", sessionId: sessionId, prompt: prompt,
                         response: nil, images: digests, started: started,
                         metadata: metadata, status: Self.status(of: error),
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
        digests: inout [ImageDigest]
    ) async throws -> InferenceResponse {
        guard checkAvailability() else {
            throw InferenceError.modelUnavailable(getAvailabilityMessage())
        }
        guard !(newSession && sessionId != nil) else {
            throw InferenceError.invalidRequest("Pass either session_id or new_session, not both. To clear an existing session, use reset")
        }
        guard !(reset && sessionId == nil) else {
            throw InferenceError.invalidRequest("reset requires session_id. To start a fresh session, use new_session")
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
        guard model.capabilities.contains(.vision) else {
            throw InferenceError.visionUnsupported
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

    public func classify(_ request: ClassifyRequest) async throws -> ClassifyResponse {
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
            await record(endpoint: "/classify", sessionId: nil, prompt: request.hint,
                         response: nil, classes: request.classes, images: digests,
                         started: started, metadata: request.metadata,
                         status: Self.status(of: error), error: Self.reason(of: error))
            throw error
        }
    }

    private func runClassify(_ request: ClassifyRequest, started: Date, digests: inout [ImageDigest]) async throws -> ClassifyResponse {
        guard checkAvailability() else {
            throw InferenceError.modelUnavailable(getAvailabilityMessage())
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
        guard model.capabilities.contains(.vision) else {
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
