import Foundation

/// How much of a session's context budget is spent.
///
/// `used` is measured, not estimated: it comes from
/// `SystemLanguageModel.tokenCount(for:)` over the session's own transcript, and
/// `limit` is the model's reported `contextSize`. Neither is hardcoded.
///
/// `used` is optional because the measurement is not always available. On macOS
/// 27.0 the model refuses to count any transcript containing an image, failing
/// with `ModelManagerError 1001`; inference on that session keeps working
/// normally, only the count is lost. A caller must therefore be able to render a
/// session whose cost is unknown — hence `nil` and a `note` rather than an error.
public struct ContextUsage: Codable, Sendable {
    public let used: Int?
    public let limit: Int
    /// Present only when `used` is nil, explaining why.
    public let note: String?

    public init(used: Int?, limit: Int, note: String? = nil) {
        self.used = used
        self.limit = limit
        self.note = note
    }

    public var remaining: Int? {
        guard let used else { return nil }
        return max(0, limit - used)
    }

    /// 0.0–1.0, or nil when unmeasured.
    public var fraction: Double? {
        guard let used, limit > 0 else { return nil }
        return Double(used) / Double(limit)
    }

    enum CodingKeys: String, CodingKey {
        case used, limit, remaining, fraction, note
    }

    /// `remaining` and `fraction` are derived, but they are encoded anyway so a
    /// non-Swift client does not have to re-derive them and get it subtly wrong.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(used, forKey: .used)
        try container.encode(limit, forKey: .limit)
        try container.encode(remaining, forKey: .remaining)
        try container.encode(fraction, forKey: .fraction)
        try container.encode(note, forKey: .note)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        used = try container.decodeIfPresent(Int.self, forKey: .used)
        limit = try container.decode(Int.self, forKey: .limit)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}
