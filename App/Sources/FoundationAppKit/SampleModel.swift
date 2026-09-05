import Foundation
import Observation
import FoundationCore

/// The image workbench: one image, one question, asked several times.
///
/// Every run is kept rather than replaced. Comparing runs *is* the tool — a
/// single answer from this model tells you almost nothing, and the interesting
/// question is always what changed between two phrasings.
@MainActor
@Observable
public final class SampleModel {

    /// What shape of answer the model is allowed to give.
    ///
    /// This is the difference between a number that means something and one that
    /// does not. Over free prose, six answers that all say "yes, there are
    /// animals" are six distinct strings, and agreement measures wording. Given a
    /// closed set the same question returns 6/6 — measured, on a driveway frame.
    public enum AnswerShape: String, CaseIterable, Identifiable, Sendable {
        case freeText = "Free text"
        case yesNo = "Yes / No"
        case choices = "Choices"
        /// A JSON object with caller-defined fields, by guided generation.
        /// Agreement compares whole objects.
        case json = "JSON"
        public var id: String { rawValue }
    }

    public struct Run: Identifiable, Sendable {
        public let id = UUID()
        public let model: ModelChoice
        public let prompt: String
        public let instructions: String?
        public let imageName: String?
        public let choices: [String]?
        public let schema: OutputSchema?
        /// Region of the original that was sent, in pixels, or nil for the whole
        /// frame. Recorded because "same question, tighter crop" is the entire
        /// experiment — a run is not interpretable without knowing what was sent.
        public let cropPixels: CGRect?
        public let sentWidth: Int?
        public let sentHeight: Int?
        public let result: SampleRun
        public let at: Date
    }

    private let service: InferenceService

    public var prompt: String = ""
    public var instructions: String = ""
    public var samples: Int = 3
    public var shape: AnswerShape = .freeText
    /// Longest edge of whatever gets sent, frame or crop. The single most
    /// influential variable measured so far: the same turkey reads as `dog` at
    /// driveway scale and `turkey` at ~280px, so it belongs in the UI rather
    /// than baked into a constant.
    public var maxDimension: Int = 1024
    public static let dimensionChoices = [256, 384, 512, 768, 1024, 1536, 2048]
    /// Comma-separated, used when `shape` is `.choices`.
    public var choicesText: String = ""
    /// One field per line, used when `shape` is `.json`. Seeded with the
    /// question an image is most often asked.
    public var schemaText: String = "subjects: string[]  every distinct thing visible in the image"

    /// Why `schemaText` cannot be used as written, or nil when it can.
    public var schemaProblem: String? { SchemaEditor.problem(in: schemaText) }

    /// The schema in force, or nil unless the shape is JSON and it parses.
    public var resolvedSchema: OutputSchema? {
        guard shape == .json else { return nil }
        return try? OutputSchema.parse(schemaText)
    }

    public private(set) var image: LoadedImage?
    public private(set) var imageName: String?
    /// Selected region in normalized 0–1 coordinates, or nil for the whole frame.
    public var selection: CGRect?
    /// Newest first, so the results read in the order the work happened.
    public private(set) var runs: [Run] = []
    public private(set) var isRunning = false
    public private(set) var failure: String?
    /// The model every run is sent to. Each sample is its own session, so
    /// switching takes effect on the next run with nothing to retire.
    public var selectedModel: ModelChoice = .onDevice
    public private(set) var status: [ModelChoice: StatusResponse] = [:]

    public init(service: InferenceService = InferenceService()) {
        self.service = service
    }

    public func start() async {
        for model in ModelChoice.allCases {
            status[model] = await service.status(model: model)
        }
        if !availableModels.contains(selectedModel) {
            selectedModel = availableModels.first ?? .onDevice
        }
    }

    /// The models that can answer right now. A model counts as available
    /// until it is known not to be, so the menu does not flicker at launch.
    public var availableModels: [ModelChoice] {
        ModelChoice.allCases.filter { status[$0]?.available ?? true }
    }

    /// The variant name, e.g. "AFM 3 Core Advanced", for labelling results.
    public func name(of model: ModelChoice) -> String {
        status[model]?.variant ?? model.displayName
    }

    /// Every result on screen as plain text, oldest first, so it reads as a log.
    /// Each entry states its conditions — model, prompt, system prompt, crop,
    /// resolution — alongside its numbers; a number without its conditions is
    /// not a result.
    public var resultsText: String {
        var lines: [String] = []
        for run in runs.reversed() {
            lines.append("Model: \(name(of: run.model))")
            lines.append("Prompt: \(run.prompt)")
            if let instructions = run.instructions {
                lines.append("System prompt: \(instructions)")
            }
            if let w = run.sentWidth, let h = run.sentHeight {
                let what = run.cropPixels.map { "crop \(Int($0.width))×\(Int($0.height))" } ?? "whole frame"
                lines.append("Image: \(run.imageName ?? "image") · \(what) → sent \(w)×\(h)")
            }
            if let choices = run.choices {
                lines.append("Choices: \(choices.joined(separator: " · "))")
            }
            if let schema = run.schema {
                lines.append("Schema:")
                for line in schema.text.split(separator: "\n") {
                    lines.append("  \(line)")
                }
            }
            lines.append("Samples: \(run.result.sampleCount) · \(run.result.durationMs) ms")
            for answer in run.result.answers {
                lines.append("  \(answer.count)/\(run.result.sampleCount)  \(String(format: "%.2f", answer.agreement))  \(answer.text)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// The closed answer set in force, or nil for free text and JSON.
    public var resolvedChoices: [String]? {
        switch shape {
        case .freeText, .json:
            return nil
        case .yesNo:
            return ["yes", "no"]
        case .choices:
            let parsed = choicesText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parsed.count >= 2 ? parsed : nil
        }
    }

    public var canRun: Bool {
        guard !isRunning,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Choices needs a usable set and JSON a usable schema, otherwise Run
        // would silently fall back to free text and change what is measured.
        if shape == .choices, resolvedChoices == nil { return false }
        if shape == .json, resolvedSchema == nil { return false }
        return true
    }

    public func load(url: URL) {
        do {
            image = try ImageLoading.load(contentsOf: url)
            imageName = url.lastPathComponent
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    public func load(data: Data, name: String?) {
        do {
            image = try ImageLoading.load(data)
            imageName = name
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    public func clearImage() {
        image = nil
        imageName = nil
        selection = nil
    }

    /// What will actually be sent: the selection cut from the full-resolution
    /// original, or the downscaled whole frame.
    public func resolvedImage() -> LoadedImage? {
        guard let image else { return nil }
        guard let selection else { return try? image.resized(maxDimension: maxDimension) }
        return try? image.cropped(to: selection, maxDimension: maxDimension)
    }

    /// Human-readable description of what Run will send, shown before running so
    /// the resolution trade is visible rather than implied.
    public var sendDescription: String? {
        guard let image else { return nil }
        guard let resolved = resolvedImage() else { return nil }
        guard selection != nil else {
            return "whole frame \(image.originalWidth)×\(image.originalHeight)"
                + " · sending \(resolved.sentWidth)×\(resolved.sentHeight)"
        }
        let region = image.pixelRect(for: selection ?? .zero)
        return "selection \(Int(region.width))×\(Int(region.height)) of "
            + "\(image.originalWidth)×\(image.originalHeight) · sending "
            + "\(resolved.sentWidth)×\(resolved.sentHeight)"
    }

    public func run() async {
        guard canRun else { return }
        isRunning = true
        failure = nil
        defer { isRunning = false }

        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let choices = resolvedChoices
            let schema = resolvedSchema
            let sending = resolvedImage()
            let result = try await service.sample(
                prompt: prompt,
                images: sending.map { [$0.imageInput] } ?? [],
                instructions: trimmedInstructions.isEmpty ? nil : trimmedInstructions,
                samples: samples,
                choices: choices,
                schema: schema,
                model: selectedModel
            )
            runs.insert(Run(
                    model: selectedModel,
                    prompt: prompt,
                    instructions: trimmedInstructions.isEmpty ? nil : trimmedInstructions,
                    imageName: imageName,
                    choices: choices,
                    schema: schema,
                    cropPixels: selection.flatMap { sel in image.map { $0.pixelRect(for: sel) } },
                    sentWidth: sending?.sentWidth,
                    sentHeight: sending?.sentHeight,
                    result: result,
                    at: Date()
                ),
                at: 0
            )
        } catch let error as InferenceError {
            failure = error.reason
        } catch {
            failure = "\(error)"
        }
    }

    public func removeRun(_ id: UUID) {
        runs.removeAll { $0.id == id }
    }
}
