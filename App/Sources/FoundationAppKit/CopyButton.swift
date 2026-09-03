import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Copies a plain-text rendering of what is on screen to the clipboard, for
/// pasting into a note, an issue, or a message. The text is built at click
/// time, so the button never has to track state.
public struct CopyButton: View {
    let help: String
    let text: () -> String
    @State private var copied = false

    public init(help: String = "Copy as text", text: @escaping () -> String) {
        self.help = help
        self.text = text
    }

    public var body: some View {
        Button {
            Self.copy(text())
            // A clipboard write is silent; the icon is the confirmation.
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 14)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}
