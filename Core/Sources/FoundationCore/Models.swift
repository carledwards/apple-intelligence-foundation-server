import Foundation

/// A single image supplied alongside a prompt. `data` is base64-encoded bytes of
/// any format ImageIO can read (PNG, JPEG, HEIC, …); a `data:` URL prefix is
/// tolerated so browser-produced payloads work as-is.
public struct ImageInput: Codable, Sendable {
    public let data: String
    public let label: String?

    public init(data: String, label: String? = nil) {
        self.data = data
        self.label = label
    }
}

public struct InferenceRequest: Codable, Sendable {
    public let prompt: String
    public let sessionId: String?
    /// Create a fresh persisted session for this request and return its id,
    /// without a separate `POST /sessions` round trip. Conflicts with `sessionId`.
    public let newSession: Bool?
    /// Clear the transcript of `sessionId` before responding, freeing its context
    /// budget while keeping the id stable. Requires `sessionId`.
    public let reset: Bool?
    public let images: [ImageInput]?
    /// The system channel. Only valid alongside `newSession`, or on a one-shot
    /// request: a session fixes its instructions when it is created.
    public let instructions: String?
    /// Free-form context recorded in the log and never sent to the model.
    public let metadata: JSONValue?

    enum CodingKeys: String, CodingKey {
        case prompt
        case sessionId = "session_id"
        case newSession = "new_session"
        case reset
        case images
        case instructions
        case metadata
    }

    public init(
        prompt: String,
        sessionId: String? = nil,
        newSession: Bool? = nil,
        reset: Bool? = nil,
        images: [ImageInput]? = nil,
        instructions: String? = nil,
        metadata: JSONValue? = nil
    ) {
        self.prompt = prompt
        self.sessionId = sessionId
        self.newSession = newSession
        self.reset = reset
        self.images = images
        self.instructions = instructions
        self.metadata = metadata
    }
}

public struct InferenceResponse: Codable, Sendable {
    public let response: String
    /// The session this response was generated in, or nil for a one-shot request
    /// that was not persisted.
    public let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case response
        case sessionId = "session_id"
    }

    public init(response: String, sessionId: String?) {
        self.response = response
        self.sessionId = sessionId
    }
}

public struct StatusResponse: Codable, Sendable {
    public let available: Bool
    public let message: String
    /// Display name of the on-device model variant, e.g. "AFM 3 Core Advanced".
    public let variant: String
    public let contextSize: Int
    public let supportsVision: Bool
    public let supportsGuidedGeneration: Bool
    public let supportsReasoning: Bool

    enum CodingKeys: String, CodingKey {
        case available
        case message
        case variant
        case contextSize = "context_size"
        case supportsVision = "supports_vision"
        case supportsGuidedGeneration = "supports_guided_generation"
        case supportsReasoning = "supports_reasoning"
    }

    public init(
        available: Bool,
        message: String,
        variant: String,
        contextSize: Int,
        supportsVision: Bool,
        supportsGuidedGeneration: Bool,
        supportsReasoning: Bool
    ) {
        self.available = available
        self.message = message
        self.variant = variant
        self.contextSize = contextSize
        self.supportsVision = supportsVision
        self.supportsGuidedGeneration = supportsGuidedGeneration
        self.supportsReasoning = supportsReasoning
    }
}

public struct ClassifyRequest: Codable, Sendable {
    /// The closed set of labels the model must choose from. Include "none" or
    /// "other" — a constrained schema forces a pick, so without an escape hatch
    /// an unlisted subject is reported as whichever listed label fits worst.
    public let classes: [String]
    public let images: [ImageInput]
    /// Optional framing, e.g. "night-vision frame from a driveway camera".
    public let hint: String?
    /// Run the classification this many times and report how often each label
    /// came up. Grounded, unlike a model's self-reported confidence.
    public let samples: Int?
    /// Most labels a single sample may return, 1–10 (default 5). Set to 1 to
    /// force a single best label instead of everything visible.
    public let maxLabels: Int?
    public let metadata: JSONValue?

    enum CodingKeys: String, CodingKey {
        case classes
        case images
        case hint
        case samples
        case maxLabels = "max_labels"
        case metadata
    }

    public init(
        classes: [String],
        images: [ImageInput],
        hint: String? = nil,
        samples: Int? = nil,
        maxLabels: Int? = nil,
        metadata: JSONValue? = nil
    ) {
        self.classes = classes
        self.images = images
        self.hint = hint
        self.samples = samples
        self.maxLabels = maxLabels
        self.metadata = metadata
    }
}

/// One label the model reported, with how consistently it did so.
public struct ClassifiedSubject: Codable, Sendable {
    public let label: String
    public let votes: Int
    /// Fraction of samples that included this label, 0.0–1.0. Numeric so callers
    /// can threshold directly (`agreement >= 0.67`) without parsing.
    public let agreement: Double

    public init(label: String, votes: Int, agreement: Double) {
        self.label = label
        self.votes = votes
        self.agreement = agreement
    }
}

public struct ClassifyResponse: Codable, Sendable {
    /// Every label seen, most consistent first. A scene with a person walking a
    /// dog returns both — the model is not forced to pick one.
    public let subjects: [ClassifiedSubject]
    public let sampleCount: Int
    /// The raw label set from each sample, in order.
    public let samples: [[String]]
    public let durationMs: Int

    enum CodingKeys: String, CodingKey {
        case subjects
        case sampleCount = "sample_count"
        case samples
        case durationMs = "duration_ms"
    }

    public init(subjects: [ClassifiedSubject], sampleCount: Int, samples: [[String]], durationMs: Int) {
        self.subjects = subjects
        self.sampleCount = sampleCount
        self.samples = samples
        self.durationMs = durationMs
    }
}
