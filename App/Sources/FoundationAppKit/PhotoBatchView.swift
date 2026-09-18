import SwiftUI
import UniformTypeIdentifiers
import FoundationCore

/// The photo workbench: add photos, put a circle on each subject, read what the model says
/// about the frame and the circle, and export the lot as a labels file.
public struct PhotoBatchView: View {
    @State private var model = PhotoBatchModel()
    @State private var picking = false
    @State private var exporting = false
    @Environment(\.horizontalSizeClass) private var sizeClass



    public init() {}

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            toolbar
                .padding(12)
            Divider()
            HStack(spacing: 0) {
                photoList
                    .frame(width: 220)
                Divider()
                if let item = model.selected {
                    PhotoCropPane(item: item) { model.cropChanged(item) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ScrollView {
                        verdictColumn(item)
                            .padding(12)
                    }
                    .frame(width: 300)
                } else {
                    ContentUnavailableView("Add photos", systemImage: "photo.stack", description: Text("Drop in a folder's worth. Each gets a circle; the model reads the frame and the circle."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls: urls) }
        }
        .fileExporter(isPresented: $exporting,
                      document: FolderExport(files: ["labels.csv": model.csv, "summary.md": model.summary, "photos.json": model.json]),
                      contentType: .folder,
                      defaultFilename: "photos-export") { _ in exporting = false }
        .task { await model.start() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ModelMenu(selection: $model.selectedModel, models: model.availableModels, status: model.status, disabled: model.runningCount > 0)
                Button("Add Photos…") { picking = true }
                Button(model.items.contains { $0.isStale } ? "Run stale" : "Run all") { model.runAll(onlyStale: model.items.contains { $0.isStale }) }
                    .disabled(model.items.isEmpty)
                Toggle("Re-run as circles move", isOn: $model.runOnChange)
                    .toggleStyle(.checkbox)
                Toggle("Read text on run", isOn: $model.readTextOnRun)
                    .toggleStyle(.checkbox)
                    .help("Vision reads the words; the model says what they tell us. Off by default.")
                Spacer()
                if model.runningCount > 0 || !model.queued.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("\(model.queued.count + model.runningCount) to go").font(.caption).foregroundStyle(.secondary)
                }
                CopyButton(help: "Copy the summary") { model.summary }
                Button("Export\(model.checked.isEmpty ? "" : " (\(model.checked.count) checked)")…") { exporting = true }
                    .help("A folder with labels.csv, summary.md, and photos.json")
                    .disabled(model.items.isEmpty)
            }
            HStack(spacing: 10) {
                Text("Classes").font(.caption.weight(.semibold))
                TextField("person, pet, vehicle, home, food, scenery, none", text: $model.classesText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                Stepper("Samples \(model.samples)", value: $model.samples, in: 1...9)
                    .font(.caption)
                    .fixedSize()
                Text("Send at").font(.caption.weight(.semibold))
                Menu(model.sizesLabel) {
                    ForEach(PhotoBatchModel.dimensionChoices, id: \.self) { size in
                        Toggle("\(size) px", isOn: Binding(
                            get: { model.selectedSizes.contains(size) },
                            set: { _ in model.toggleSize(size) }))
                    }
                    Divider()
                    Button("All sizes") { model.selectedSizes = Set(PhotoBatchModel.dimensionChoices) }
                    Button("1024 only") { model.selectedSizes = [1024] }
                }
                .fixedSize()
                .help("Each checked size is run and kept; several make a sweep.")
                Spacer()
            }
            HStack(spacing: 10) {
                Text("Sentence").font(.caption.weight(.semibold))
                TextField("Describe this photo in one short sentence.", text: $model.sentencePrompt)
                    .textFieldStyle(.roundedBorder)
                Text("Hint").font(.caption.weight(.semibold))
                TextField("optional framing", text: $model.hint)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
        }
    }

    // MARK: List

    private var photoList: some View {
        @Bindable var model = model
        return List(selection: $model.selectedID) {
            ForEach(model.items) { item in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { model.checked.contains(item.id) },
                        set: { if $0 { model.checked.insert(item.id) } else { model.checked.remove(item.id) } }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Image(decorative: item.image.display, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.caption).lineLimit(1)
                        HStack(spacing: 4) {
                            if item.isRunning {
                                ProgressView().controlSize(.mini)
                            } else if item.failure != nil {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red).font(.caption2)
                            } else if item.verdict != nil {
                                Text(model.kinds(for: item).joined(separator: "|"))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(item.isStale ? .secondary : .primary)
                                if item.isStale { Text("stale").font(.caption2).foregroundStyle(.secondary) }
                            } else {
                                Text("not run").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .tag(item.id)
                .contextMenu {
                    Button("Run") { model.schedule(item) }
                    Button("Remove", role: .destructive) { model.remove(item.id) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Verdict

    private func verdictColumn(_ item: PhotoItem) -> some View {
        @Bindable var item = item
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.name).font(.headline).lineLimit(1)
                Spacer()
                Button(item.isReadingText ? "Reading…" : "Read text") { Task { await model.readText(item) } }
                    .controlSize(.small)
                    .disabled(item.isReadingText)
                Button("Run") { model.schedule(item) }
                    .controlSize(.small)
                    .disabled(item.isRunning)
            }
            Text("\(item.image.originalWidth)×\(item.image.originalHeight) · circle \(item.crop.exportText)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let failure = item.failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if let verdict = item.verdict {
                if item.isStale {
                    Label("Circle moved since this run", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                }
                if item.sizesRun.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("By send size").font(.caption.weight(.semibold))
                        ForEach(item.sizesRun, id: \.self) { size in
                            if let v = item.verdicts[size] {
                                HStack(spacing: 8) {
                                    Text("\(size) px").font(.caption.monospacedDigit()).frame(width: 60, alignment: .leading)
                                    Text((v.cropSubjects ?? v.fullSubjects).filter { $0.agreement >= 0.67 }.map { "\($0.label) \($0.votes)/\(model.samples)" }.joined(separator: ", "))
                                        .font(.caption).lineLimit(1)
                                    Spacer()
                                    Text("\(v.durationMs) ms").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("Details below are for \(verdict.size) px.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                section("Model · whole frame · \(verdict.sentFull.0)×\(verdict.sentFull.1)", subjects: verdict.fullSubjects)
                visionSection("Vision · whole frame", labels: verdict.fullVision)
                if let cropSubjects = verdict.cropSubjects, let sent = verdict.sentCrop {
                    section("Model · circle · \(sent.0)×\(sent.1)", subjects: cropSubjects)
                    visionSection("Vision · circle", labels: verdict.cropVision ?? [])
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Says").font(.caption.weight(.semibold))
                    Text(verdict.sentence).font(.callout).textSelection(.enabled)
                    if let cropSentence = verdict.cropSentence {
                        Text("Of the circle").font(.caption.weight(.semibold)).padding(.top, 4)
                        Text(cropSentence).font(.callout).textSelection(.enabled)
                    }
                }
                Text("\(verdict.durationMs) ms · \(model.samples) samples")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if item.isRunning {
                ProgressView("Asking…").controlSize(.small)
            }
            if let text = item.text {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text · \(text.lines.count) lines · \(text.durationMs) ms").font(.caption.weight(.semibold))
                    if text.lines.isEmpty {
                        Text("nothing readable").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(text.reading.isEmpty ? "The model inferred nothing from it." : text.reading)
                            .font(.callout).textSelection(.enabled)
                        ForEach(text.lines.prefix(12), id: \.self) { line in
                            HStack(spacing: 6) {
                                Text(line.text).font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                Text(String(format: "%.2f", line.confidence)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        if text.lines.count > 12 { Text("… \(text.lines.count - 12) more").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Your notes").font(.caption.weight(.semibold))
                TextField("What is really in it (exported as notes)", text: $item.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
            HStack(spacing: 6) {
                Text("Exports as").font(.caption.weight(.semibold))
                Text(model.kinds(for: item).joined(separator: "|")).font(.caption.monospaced())
            }
        }
    }

    /// Vision's labels with their own confidence, which unlike the model's is a real number.
    private func visionSection(_ title: String, labels: [VisionLabel]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            if labels.isEmpty {
                Text("nothing above 0.3").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(labels, id: \.label) { seen in
                HStack(spacing: 8) {
                    Text(seen.label).font(.callout.monospaced()).frame(width: 120, alignment: .leading).lineLimit(1).truncationMode(.tail)
                    ProgressView(value: seen.confidence).tint(.blue)
                    Text(String(format: "%.2f", seen.confidence)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func section(_ title: String, subjects: [ClassifiedSubject]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            if subjects.isEmpty {
                Text("nothing").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(subjects, id: \.label) { subject in
                HStack(spacing: 8) {
                    Text(subject.label).font(.callout.monospaced()).frame(width: 120, alignment: .leading).lineLimit(1)
                    ProgressView(value: subject.agreement)
                        .tint(subject.agreement >= 0.67 ? .green : .orange)
                    Text("\(subject.votes)/\(model.samples)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The photo with one circle on it. Drag to move the circle, pinch or use the slider to
/// tighten it. The circle's bounding square, cut from the full-resolution original, is what
/// the model sees as "the subject".
struct PhotoCropPane: View {
    @Bindable var item: PhotoItem
    var onChange: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let frame = fittedFrame(in: geo.size)
                ZStack {
                    Color.black.opacity(0.04)
                    Image(decorative: item.image.display, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    circleOverlay(frame: frame)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    item.crop.cx = min(max((value.location.x - frame.minX) / frame.width, 0), 1)
                    item.crop.cy = min(max((value.location.y - frame.minY) / frame.height, 0), 1)
                }.onEnded { _ in onChange() })
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    item.crop.zoom = min(max(item.crop.zoom * value.magnification, 1), 8)
                }.onEnded { _ in onChange() })
            }
            HStack(spacing: 10) {
                Text("Zoom").font(.caption.weight(.semibold))
                Slider(value: $item.crop.zoom, in: 1...8) { editing in if !editing { onChange() } }
                    .frame(maxWidth: 220)
                Text(String(format: "%.1f×", item.crop.zoom)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(cropSizeText).font(.caption).foregroundStyle(.secondary)
                Button("Whole frame") { item.crop = CircleCrop(); onChange() }.font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    /// The circle's square in pixels of the original, so the 384 px floor is visible.
    private var cropSizeText: String {
        let side = Int(Double(min(item.image.originalWidth, item.image.originalHeight)) / item.crop.zoom)
        return item.crop.isWholeFrame ? "whole frame" : "cuts \(side)×\(side) px\(side < 384 ? " · under 384" : "")"
    }

    private func fittedFrame(in size: CGSize) -> CGRect {
        let aspect = CGFloat(item.image.display.width) / CGFloat(item.image.display.height)
        var width = size.width, height = width / aspect
        if height > size.height { height = size.height; width = height * aspect }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func circleOverlay(frame: CGRect) -> some View {
        let rect = item.crop.normalizedRect(width: item.image.originalWidth, height: item.image.originalHeight)
        let box = CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height,
                         width: rect.width * frame.width, height: rect.height * frame.height)
        return ZStack {
            Rectangle()
                .fill(.black.opacity(item.crop.isWholeFrame ? 0 : 0.35))
                .mask {
                    ZStack {
                        Rectangle()
                        Circle().frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY).blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
        }
        .allowsHitTesting(false)
    }
}

/// One export, a folder: labels.csv for the harness, summary.md to read, photos.json for
/// anything else. Nothing to choose.
struct FolderExport: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    var files: [String: String]
    init(files: [String: String]) { self.files = files }
    init(configuration: ReadConfiguration) throws { files = [:] }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrappers = files.mapValues { FileWrapper(regularFileWithContents: Data($0.utf8)) }
        return FileWrapper(directoryWithFileWrappers: wrappers)
    }
}
