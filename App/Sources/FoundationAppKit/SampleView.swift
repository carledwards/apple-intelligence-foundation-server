import SwiftUI
#if os(macOS)
import AppKit
#else
import PhotosUI
#endif
import UniformTypeIdentifiers
import FoundationCore

public struct SampleView: View {
    @State private var model = SampleModel()
    @State private var picking = false
    #if !os(macOS)
    @State private var photoItem: PhotosPickerItem?
    #endif
    // Phone-width layouts stack what the Mac fits in one row.
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    @State private var requestedPaneHeight: CGFloat = 260
    @State private var committedPaneHeight: CGFloat = 260
    @State private var dragging = false

    public init() {}

    public var body: some View {
        // On a wide window the image and its controls are an instrument panel:
        // they stay put while results accumulate below. On a phone that panel
        // is taller than the screen, so the whole workbench scrolls as one.
        GeometryReader { outer in
            if compact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        panel(maxHeight: outer.size.height)
                        Divider()
                        results
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
            } else {
                VStack(spacing: 0) {
                    panel(maxHeight: outer.size.height)
                        .padding(14)
                    Divider()
                    ScrollView {
                        results
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { model.load(url: url) }
        }
        #if !os(macOS)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    model.load(data: data, name: "photo")
                }
                photoItem = nil
            }
        }
        #endif
        .task { await model.start() }
    }

    /// The image, its controls, and the inputs — everything above the results.
    private func panel(maxHeight: CGFloat) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            ModelMenu(
                selection: $model.selectedModel,
                models: model.availableModels,
                status: model.status,
                disabled: model.isRunning
            )
            imageWell(maxHeight: maxHeight)
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            controls
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.runs.isEmpty {
                hint
            } else {
                HStack {
                    Text("Results")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    CopyButton(help: "Copy all results as text") { model.resultsText }
                }
                ForEach(model.runs) { run in
                    runCard(run)
                }
            }
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
                    Text(model.imageName ?? "image")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Picker("Send at", selection: $model.maxDimension) {
                        ForEach(SampleModel.dimensionChoices, id: \.self) { Text("\($0)px").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .font(.caption)
                    Spacer()
                    Button("Remove") { model.clearImage() }.font(.caption)
                }
                // What is actually sent is stated, never implied: downscaling
                // and cropping both change the answer. Its own line, so it is
                // never truncated to make room for the controls.
                if let description = model.sendDescription {
                    Text(description)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.selection == nil ? .secondary : Color.accentColor)
                }
            } else {
                #if os(macOS)
                dropWell
                    .onTapGesture { picking = true }
                #else
                // The photo library is where an iPhone's images are, so the
                // well itself opens it. Files and the clipboard are the row
                // below. Drop still works on iPad.
                PhotosPicker(selection: $photoItem, matching: .images) { dropWell }
                    .buttonStyle(.plain)
                #endif
                sourcesRow
            }
        }
    }

    /// The other ways in. `PasteButton` enables itself only while the
    /// clipboard holds an image, and reads it without the paste permission
    /// prompt that `UIPasteboard` access would raise.
    private var sourcesRow: some View {
        HStack(spacing: 12) {
            #if !os(macOS)
            Button("Files…") { picking = true }
            #endif
            PasteButton(payloadType: PastedImage.self) { items in
                guard let first = items.first else { return }
                model.load(data: first.data, name: "pasted image")
            }
            .labelStyle(.titleOnly)
            Spacer()
        }
        .font(.caption)
        .controlSize(.small)
    }

    private var dropWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(.secondary.opacity(0.5))
            VStack(spacing: 4) {
                Image(systemName: "photo.on.rectangle.angled").font(.title2)
                #if os(macOS)
                Text("Drop an image, or click to choose a file").font(.caption)
                #else
                Text("Tap to choose a photo").font(.caption)
                #endif
            }
            .foregroundStyle(.secondary)
        }
        .frame(height: 180)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.load(url: url)
            return true
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
            TextField("System prompt (optional)",
                      text: $model.instructions, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            TextField("Question, e.g. \"What animals are in this image?\"",
                      text: $model.prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            if compact {
                shapePicker
                HStack(spacing: 10) {
                    samplesStepper
                    Spacer()
                    if model.isRunning { ProgressView().controlSize(.small) }
                    runButton
                }
            } else {
                HStack(spacing: 10) {
                    shapePicker.fixedSize()
                    samplesStepper.fixedSize()
                    Spacer()
                    if model.isRunning { ProgressView().controlSize(.small) }
                    runButton
                }
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

            if model.shape == .json {
                SchemaEditor(text: $model.schemaText, problem: model.schemaProblem)
                Text("Agreement compares whole objects. Field order is normalized; the order of items inside a list is not, so the same things listed in a different order count as different answers.")
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

    private var shapePicker: some View {
        @Bindable var model = model
        return Picker("", selection: $model.shape) {
            ForEach(SampleModel.AnswerShape.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var samplesStepper: some View {
        @Bindable var model = model
        return Stepper("Samples: \(model.samples)", value: $model.samples, in: 1...9)
    }

    /// ⌘↩ is macOS-only: on iOS a key-command button whose enabled state
    /// changes resigns the focused text field's first responder.
    private var runButton: some View {
        #if os(macOS)
        Button("Run") { Task { await model.run() } }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canRun)
        #else
        Button("Run") { Task { await model.run() } }
            .disabled(!model.canRun)
        #endif
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
                    model.removeRun(run.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            // The device model is the default and goes unsaid; any other
            // model is named, because that is what changed.
            if run.model != .onDevice {
                Label(model.name(of: run.model), systemImage: "cloud")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
            if let schema = run.schema {
                Label(schema.fields.map { "\($0.name): \($0.type)" }.joined(separator: " · "),
                      systemImage: "curlybraces")
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
                    AnswerText(text: answer.text)
                        .font(.callout)
                }
            }

            if run.result.answers.count > 1 {
                Text(splitNote(for: run))
                    .font(.caption2)
                    .foregroundStyle(run.choices == nil && run.schema == nil ? Color.secondary : Color.orange)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    /// What a split means depends on what constrained the answer. Free text
    /// splits on wording; a closed set or a schema splits on the answer itself.
    private func splitNote(for run: SampleModel.Run) -> String {
        let n = run.result.answers.count
        if run.schema != nil {
            return "Split \(n) ways — the same fields with different values. Key order is normalized; the order of items inside a list is not."
        }
        if run.choices != nil {
            return "Split \(n) ways — the model gave different answers to the same question."
        }
        return "\(n) distinct wordings. Over free text this counts phrasing, not meaning — re-run with a closed answer set to see whether the answers actually differ."
    }

    private func tint(_ agreement: Double) -> Color {
        switch agreement {
        case ..<0.5: return .red
        case ..<0.8: return .orange
        default: return .green
        }
    }
}
