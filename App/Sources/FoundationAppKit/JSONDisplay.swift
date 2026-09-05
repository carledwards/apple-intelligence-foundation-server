import SwiftUI

/// Renders a model answer, pretty-printing it when it is JSON.
///
/// Structured answers arrive as one compact line with sorted keys. That is the
/// right form to compare and to copy; it is not the right form to read, so on
/// screen an object is indented one field per line and set in monospace. Prose
/// is shown as it came.
struct AnswerText: View {
    let text: String

    var body: some View {
        if let pretty = Self.pretty(text) {
            Text(pretty)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The indented form of `text` if it is a JSON object or array, else nil.
    /// Keys stay in the order they arrive — already sorted by the model layer.
    static func pretty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return String(data: formatted, encoding: .utf8)
    }
}
