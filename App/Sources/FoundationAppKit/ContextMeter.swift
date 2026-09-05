import SwiftUI
import FoundationCore

/// Shows how close the conversation is to the context ceiling.
///
/// The ceiling is treated as information rather than an error to be hidden: a
/// developer testing a prompt needs to know how many turns — or how many images —
/// it survives before the window fills, because that is the constraint that will
/// break the app they are actually building.
public struct ContextMeter: View {
    let title: String
    let usage: ContextUsage?
    let turns: Int

    public init(title: String = "Context", usage: ContextUsage?, turns: Int) {
        self.title = title
        self.usage = usage
        self.turns = turns
    }

    private var fraction: Double { usage?.fraction ?? 0 }

    private var tint: Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                if let usage, let used = usage.used {
                    Text("\(used) / \(usage.limit) tokens")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    // The honest fallback. tokenCount refuses any transcript
                    // containing an image, so turns are all that can be counted.
                    Text("\(turns) message\(turns == 1 ? "" : "s") sent · not measurable")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if usage?.used != nil {
                ProgressView(value: min(fraction, 1))
                    .tint(tint)
            } else {
                ProgressView(value: 0)
                    .tint(.gray)
                    .opacity(0.35)
            }

            if let note = usage?.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }
}

// The meter has three states worth looking at side by side, and only one of them
// happens on a fresh session — so they are pinned here rather than reached by
// driving the app into each condition by hand.
#Preview("Context meter states") {
    VStack(alignment: .leading, spacing: 22) {
        ContextMeter(usage: ContextUsage(used: 200, limit: 8192), turns: 2)
        ContextMeter(usage: ContextUsage(used: 7100, limit: 8192), turns: 24)
        ContextMeter(usage: ContextUsage(used: 8100, limit: 8192), turns: 31)
        ContextMeter(
            usage: ContextUsage(
                used: nil,
                limit: 8192,
                note: "Token counting unavailable for this session (ModelManagerError 1001)"
            ),
            turns: 3
        )
        ContextMeter(usage: nil, turns: 0)
    }
    .padding()
    .frame(width: 340)
}
