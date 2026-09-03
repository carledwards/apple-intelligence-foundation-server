import Foundation

/// One distinct answer the model gave, and how often it gave it.
public struct SampledAnswer: Codable, Sendable {
    /// The first raw form of this answer, shown as typed by the model.
    public let text: String
    public let count: Int
    /// Fraction of samples that produced this answer, 0.0–1.0.
    public let agreement: Double

    public init(text: String, count: Int, agreement: Double) {
        self.text = text
        self.count = count
        self.agreement = agreement
    }
}

/// The result of asking the same question several times.
///
/// Measurements on this model put a single run somewhere between useless and
/// misleading: identical prompts returned self-reported confidence of
/// `[100, 0, 100, 100, 0, 100]` on a fixed image while the verdict stayed
/// correct, and a label at full agreement was wrong twelve times running.
/// Agreement is not accuracy — it measures whether the model is *consistent*.
/// A split vote is a reliable signal that the phrasing is doing badly; a
/// unanimous one is only the absence of that signal.
public struct SampleRun: Codable, Sendable {
    /// Distinct answers, most agreed-upon first.
    public let answers: [SampledAnswer]
    /// Every response in order, ungrouped, so it is always possible to see what
    /// the grouping did.
    public let responses: [String]
    public let sampleCount: Int
    public let durationMs: Int

    public init(answers: [SampledAnswer], responses: [String], sampleCount: Int, durationMs: Int) {
        self.answers = answers
        self.responses = responses
        self.sampleCount = sampleCount
        self.durationMs = durationMs
    }

    enum CodingKeys: String, CodingKey {
        case answers, responses
        case sampleCount = "sample_count"
        case durationMs = "duration_ms"
    }

    /// How often the single most common answer came up. The headline number:
    /// 1.0 means the model never wavered, 0.2 across five samples means it said
    /// something different every time.
    public var topAgreement: Double { answers.first?.agreement ?? 0 }

    /// Groups responses that differ only in casing, surrounding whitespace, or
    /// trailing punctuation — "Bleu", "bleu." and " Bleu " are one answer.
    /// Deliberately shallow: anything cleverer would hide real disagreement
    /// behind a similarity threshold nobody can audit.
    public static func key(for response: String) -> String {
        response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: \n\t"))
    }
}
