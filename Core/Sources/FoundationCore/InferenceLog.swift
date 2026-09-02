import Foundation

/// Identifies an image without storing it. The digest is enough to correlate a
/// log line back to the source frame and to spot repeated frames.
public struct ImageDigest: Encodable, Sendable {
    public let sha256: String
    public let bytes: Int
    public let width: Int
    public let height: Int

    public init(sha256: String, bytes: Int, width: Int, height: Int) {
        self.sha256 = sha256
        self.bytes = bytes
        self.width = width
        self.height = height
    }
}

public struct LogRecord: Encodable, Sendable {
    public let ts: String
    public let endpoint: String
    public let sessionId: String?
    public let prompt: String?
    public let response: String?
    public let classes: [String]?
    public let images: [ImageDigest]
    public let durationMs: Int
    public let modelVariant: String
    public let metadata: JSONValue?
    public let status: Int
    public let error: String?

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

    public init(
        ts: String,
        endpoint: String,
        sessionId: String?,
        prompt: String?,
        response: String?,
        classes: [String]?,
        images: [ImageDigest],
        durationMs: Int,
        modelVariant: String,
        metadata: JSONValue?,
        status: Int,
        error: String?
    ) {
        self.ts = ts
        self.endpoint = endpoint
        self.sessionId = sessionId
        self.prompt = prompt
        self.response = response
        self.classes = classes
        self.images = images
        self.durationMs = durationMs
        self.modelVariant = modelVariant
        self.metadata = metadata
        self.status = status
        self.error = error
    }

    /// Written explicitly rather than synthesized so every record carries every
    /// key, with `null` where a value is absent. Synthesis uses `encodeIfPresent`,
    /// which drops keys and leaves the log ragged — awkward for `jq` and for
    /// anything that loads it as a table.
    public func encode(to encoder: Encoder) throws {
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

/// Appends one JSON object per request to a file. On the server this is enabled
/// by setting `LOG_FILE`; when no log is supplied nothing is written anywhere.
public actor InferenceLog {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw InferenceError.logUnavailable("Could not create log file at \(path)")
            }
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    public static func timestamp() -> String {
        formatter.string(from: Date())
    }

    public func write(_ record: LogRecord) {
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A) // newline
        try? handle.write(contentsOf: data)
    }

    public func close() {
        try? handle.close()
    }
}
