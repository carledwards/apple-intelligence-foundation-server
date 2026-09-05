import SwiftUI
import FoundationCore

/// Edits an `OutputSchema` in its text form, one field per line.
///
/// A `TextEditor`, not a `TextField`: Return has to insert a line, and in a
/// `TextField` it submits. The help line doubles as the error line — the
/// parse problem, when there is one, replaces the format reminder.
public struct SchemaEditor: View {
    @Binding var text: String
    let problem: String?

    public init(text: Binding<String>, problem: String?) {
        self._text = text
        self.problem = problem
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.callout.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(minHeight: 56, maxHeight: 160)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.secondary.opacity(0.35), lineWidth: 1)
                        )
                    if text.isEmpty {
                        Text("name: type  description")
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 5)
                    .help("Clear the schema")
                }
            }

            Text(problem
                 ?? "One field per line: name, type, then an optional description the model reads as its guide. Types: string, number, integer, bool; add [] for a list, [N] for exactly N, nested as needed — integer[4][] is a list of boxes.")
                .font(.caption2)
                .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
        }
    }

    /// Why `text` cannot be used as a schema, or nil when it can.
    public static func problem(in text: String) -> String? {
        do {
            _ = try OutputSchema.parse(text)
            return nil
        } catch let error as InferenceError {
            return error.reason
        } catch {
            return "\(error)"
        }
    }
}
