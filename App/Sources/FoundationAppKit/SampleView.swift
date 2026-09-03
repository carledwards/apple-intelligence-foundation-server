import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers
import FoundationCore

public struct SampleView: View {
    @State private var model = SampleModel()
    @State private var picking = false
    @State private var requestedPaneHeight: CGFloat = 260
    @State private var committedPaneHeight: CGFloat = 260
    @State private var dragging = false

    public init() {}

    public var body: some View {
        @Bindable var model = model
        // The image and its controls are an instrument panel: they stay put while
        // results accumulate below. Scrolling the whole workbench also let the
        // image slide up beneath the floating tab bar, which no amount of
        // clipping inside the pane can prevent — the pane itself was moving.
        return GeometryReader { outer in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    imageWell(maxHeight: outer.size.height)
                    if let failure = model.failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    controls
                }
                .padding(14)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.entries.isEmpty {
                            hint
                        } else {
                            ForEach(model.entries) { entry in
                                switch entry {
                                case .run(let run): runCard(run)
                                case .sweep(let sweep): sweepCard(sweep)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { model.load(url: url) }
        }
    }

    /// Never let the panel eat the whole window: results have to stay visible or
    /// the comparison the tool exists for is off screen.
    private func paneHeight(fitting available: CGFloat) -> CGFloat {
        guard available > 0 else { return requestedPaneHeight }
        return min(requestedPaneHeight, max(140, available * 0.62))
    }

    // MARK: Image

    private func imageWell(maxHeight: CGFloat) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            if let image = model.image {
                ImagePane(image: image, selection: $model.selection)
                    .frame(height: paneHeight(fitting: maxHeight))
                    .clipped()
                resizeHandle
                HStack(spacing: 8) {
                    Text(model.imageName ?? "image").font(.caption.weight(.medium))
                    Picker("Send at", selection: $model.maxDimension) {
                        ForEach(SampleModel.dimensionChoices, id: \.self) { Text("\($0)px").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .font(.caption)
                    // What is actually sent is stated, never implied: downscaling
                    // and cropping both change the answer.
                    if let description = model.sendDescription {
                        Text(description)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(model.selection == nil ? .secondary : Color.accentColor)
                    }
                    Spacer()
                    Button("Remove") { model.clearImage() }.font(.caption)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(.secondary.opacity(0.5))
                    VStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle.angled").font(.title2)
                        Text("Drop an image, or click to choose").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(height: 180)
                .contentShape(Rectangle())
                .onTapGesture { picking = true }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    model.load(url: url)
                    return true
                }
            }
        }
    }

    /// Drag down to give the image more room. A camera frame at 220pt is too
    /// small to pick a subject out of, which is exactly what selection needs.
    private var resizeHandle: some View {
        ZStack {
            Rectangle().fill(.clear).frame(height: 14)
            Capsule()
                .fill(.secondary.opacity(dragging ? 0.7 : 0.35))
                .frame(width: 44, height: 4)
        }
        .contentShape(Rectangle())
        // Measured in global coordinates on purpose. The handle lives inside the
        // view it resizes, so in local coordinates it slides under the cursor as
        // the pane grows and feeds that movement back into the translation — the
        // drag then chases itself and the pane judders.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    requestedPaneHeight = min(900, max(160, committedPaneHeight + value.translation.height))
                }
                .onEnded { _ in
                    dragging = false
                    committedPaneHeight = requestedPaneHeight
                }
        )
        #if os(macOS)
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        #endif
    }

    // MARK: Inputs

    private var controls: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Instructions (optional) — the system channel",
                      text: $model.instructions, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            TextField("Question, e.g. \"What animals are in this image?\"",
                      text: $model.prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .opacity(model.sweepAxis == .prompts ? 0.55 : 1)
                .help(model.sweepAxis == .prompts
                      ? "Used by Run. A prompt sweep uses the variant list instead."
                      : "The question sent to the model.")
            HStack(spacing: 10) {
                Picker("", selection: $model.shape) {
                    ForEach(SampleModel.AnswerShape.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Stepper("Samples: \(model.samples)", value: $model.samples, in: 1...9)
                    .fixedSize()
                Spacer()
                if model.isRunning { ProgressView().controlSize(.small) }
                Button("Run") { Task { await model.run() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canRun)
            }

            if model.shape == .choices {
                TextField("Comma-separated answers, e.g. \"deer, turkey, person, none\"",
                          text: $model.choicesText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                if model.resolvedChoices == nil {
                    Text("Needs at least two comma-separated options.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }

            HStack(spacing: 10) {
                Picker("", selection: $model.sweepAxis) {
                    ForEach(SampleModel.SweepAxis.allCases) { Text("Sweep \($0.rawValue)").tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: model.sweepAxis) { _, axis in
                    model.prepareSweep(for: axis)
                }
                Text(model.sweepSteps.isEmpty ? "no steps" : "\(model.sweepSteps.count) steps × \(model.samples)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let progress = model.progress {
                    Text(progress).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Cancel") { model.cancel() }.font(.caption)
                } else {
                    Button("Sweep") { Task { await model.sweep() } }
                        .disabled(!model.canSweep)
                }
            }

            if model.sweepAxis == .prompts {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.promptVariants)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(minHeight: 76, maxHeight: 150)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.secondary.opacity(0.35), lineWidth: 1)
                        )
                    if model.promptVariants.isEmpty {
                        Text("One prompt per line")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                Text("Sweep runs every line here, and only these — the single prompt above is used by Run.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.shape == .freeText {
                Text("Free text answers vary in wording, so agreement below counts phrasings, not meanings. Pick a closed answer set to measure whether the model agrees on the answer.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hint: some View {
        Text("""
             Each run asks the same question `samples` times in separate sessions \
             and groups identical answers. A split vote means the phrasing is \
             unreliable. Full agreement means only that the model is consistent — \
             it is not evidence the answer is right.
             """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    // MARK: Results

    private func runCard(_ run: SampleModel.Run) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.prompt).font(.callout.weight(.medium))
                Spacer()
                Text("\(run.result.sampleCount)× · \(run.result.durationMs) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    model.removeEntry(run.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            if let instructions = run.instructions {
                Label(instructions, systemImage: "text.badge.checkmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let w = run.sentWidth, let h = run.sentHeight {
                Label(run.cropPixels.map { "crop \(Int($0.width))×\(Int($0.height)) → sent \(w)×\(h)" }
                        ?? "whole frame → sent \(w)×\(h)",
                      systemImage: run.cropPixels == nil ? "photo" : "crop")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(run.cropPixels == nil ? Color.secondary : Color.accentColor)
            }
            if let choices = run.choices {
                Label(choices.joined(separator: " · "), systemImage: "list.bullet.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ForEach(Array(run.result.answers.enumerated()), id: \.offset) { _, answer in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(format: "%.2f", answer.agreement))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(tint(answer.agreement))
                        .frame(width: 34, alignment: .trailing)
                    Text("\(answer.count)/\(run.result.sampleCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .leading)
                    Text(answer.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if run.result.answers.count > 1 {
                Text(run.choices == nil
                     ? "\(run.result.answers.count) distinct wordings. Over free text this counts phrasing, not meaning — re-run with a closed answer set to see whether the answers actually differ."
                     : "Split \(run.result.answers.count) ways — the model gave different answers to the same question.")
                    .font(.caption2)
                    .foregroundStyle(run.choices == nil ? Color.secondary : Color.orange)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    /// One row per swept value. Reading down the column is the comparison; that
    /// is the point of running them together rather than one at a time.
    private func sweepCard(_ sweep: SampleModel.Sweep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Sweep: \(sweep.axis.rawValue)", systemImage: "slider.horizontal.3")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(sweep.steps.count) steps")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    model.removeEntry(sweep.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Text("held fixed — \(sweep.held)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)

            ForEach(Array(sweep.steps.enumerated()), id: \.element.id) { index, step in
                let previous = index > 0 ? sweep.steps[index - 1].result.answers.first?.text : nil
                let changed = previous != nil && previous != step.result.answers.first?.text
                HStack(alignment: .top, spacing: 8) {
                    // A marker where the top answer flips. Finding that boundary
                    // is the reason to run a sweep rather than a single sample.
                    Text(changed ? "▸" : " ")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(step.label)
                            .font(.caption.monospacedDigit().weight(.medium))
                            .lineLimit(2)
                        // The cap is what you set; this is what was actually sent.
                        if let w = step.sentWidth, let h = step.sentHeight,
                           sweep.axis == .resolution {
                            Text("\(w)×\(h)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: sweep.axis == .resolution ? 66 : 170, alignment: .leading)

                    if let top = step.result.answers.first {
                        Text(String(format: "%.2f", top.agreement))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(tint(top.agreement))
                            .frame(width: 34, alignment: .trailing)
                        Text("\(top.count)/\(step.result.sampleCount)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(top.text)
                                .font(.callout)
                                .fontWeight(changed ? .semibold : .regular)
                                .textSelection(.enabled)
                            ForEach(Array(step.result.answers.dropFirst().enumerated()), id: \.offset) { _, other in
                                HStack(spacing: 4) {
                                    Text("also")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Text("\(other.count)/\(step.result.sampleCount)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                    Text(other.text)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let boundary = transition(in: sweep) {
                Text(boundary)
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Names the boundary when the top answer flips exactly once — the common and
    /// most readable case. Stays silent when it flips repeatedly, because then
    /// there is no single boundary to report and saying otherwise would mislead.
    private func transition(in sweep: SampleModel.Sweep) -> String? {
        var flips: [(String, String)] = []
        for index in 1..<max(sweep.steps.count, 1) {
            let before = sweep.steps[index - 1]
            let after = sweep.steps[index]
            if before.result.answers.first?.text != after.result.answers.first?.text {
                flips.append((before.label, after.label))
            }
        }
        guard flips.count == 1, let flip = flips.first else { return nil }
        return "answer changes between \(flip.0) and \(flip.1)"
    }

    private func tint(_ agreement: Double) -> Color {
        switch agreement {
        case ..<0.5: return .red
        case ..<0.8: return .orange
        default: return .green
        }
    }
}
