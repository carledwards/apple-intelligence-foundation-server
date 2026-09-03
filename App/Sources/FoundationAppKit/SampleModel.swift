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
        public var id: String { rawValue }
    }

    public struct Run: Identifiable, Sendable {
        public let id = UUID()
        public let prompt: String
        public let instructions: String?
        public let imageName: String?
        public let choices: [String]?
        /// Region of the original that was sent, in pixels, or nil for the whole
        /// frame. Recorded because "same question, tighter crop" is the entire
        /// experiment — a run is not interpretable without knowing what was sent.
        public let cropPixels: CGRect?
        public let sentWidth: Int?
        public let sentHeight: Int?
        public let result: SampleRun
        public let at: Date
    }

    /// One variable, swept across several values, everything else held fixed.
    ///
    /// Doing this by hand means changing a control and pressing Run repeatedly,
    /// which is how a confounded comparison happens: it is far too easy to change
    /// the crop and the resolution and then attribute the result to one of them.
    public enum SweepAxis: String, CaseIterable, Identifiable, Sendable {
        case resolution = "Resolution"
        case prompts = "Prompts"
        public var id: String { rawValue }
    }

    public struct Sweep: Identifiable, Sendable {
        public struct Step: Identifiable, Sendable {
            public let id = UUID()
            /// What was varied for this step — "384px", or the prompt text.
            public let label: String
            public let sentWidth: Int?
            public let sentHeight: Int?
            public let result: SampleRun
        }
        public let id = UUID()
        public let axis: SweepAxis
        /// Everything held constant, for the record.
        public let held: String
        public let steps: [Step]
        public let at: Date
    }

    /// Runs and sweeps interleaved, newest first, so the results read in the
    /// order the work actually happened.
    public enum Entry: Identifiable, Sendable {
        case run(Run)
        case sweep(Sweep)
        public var id: UUID {
            switch self {
            case .run(let r): return r.id
            case .sweep(let s): return s.id
            }
        }
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

    public private(set) var image: LoadedImage?
    public private(set) var imageName: String?
    /// Selected region in normalized 0–1 coordinates, or nil for the whole frame.
    public var selection: CGRect?
    public private(set) var entries: [Entry] = []
    public var sweepAxis: SweepAxis = .resolution
    /// One prompt variant per line. This is the complete list a prompt sweep
    /// runs — the single `prompt` above is not implicitly included, because a
    /// list you can read in full is easier to trust than one with a hidden
    /// first element.
    public var promptVariants: String = ""

    /// Called when the sweep axis changes. Seeds the variant list from the
    /// current prompt so switching to a prompt sweep never silently discards
    /// what was already typed.
    public func prepareSweep(for axis: SweepAxis) {
        guard axis == .prompts else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard promptVariants.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !trimmed.isEmpty else { return }
        promptVariants = trimmed + "\n"
    }
    public private(set) var progress: String?
    private var cancelled = false

    /// Resolutions a sweep will try, capped to what the source can supply —
    /// nothing here upscales, so a larger value would just repeat the native run.
    public static let sweepDimensions = [64, 128, 256, 384, 512, 768, 1024]
    public private(set) var isRunning = false
    public private(set) var failure: String?
    public private(set) var status: StatusResponse?

    public init(service: InferenceService = InferenceService()) {
        self.service = service
    }

    public func start() async {
        status = await service.status()
    }

    /// Every result on screen as plain text, oldest first, so it reads as a log.
    /// Each entry states its conditions — model, prompt, system prompt, crop,
    /// resolution — alongside its numbers; a number without its conditions is
    /// not a result.
    public var resultsText: String {
        var lines: [String] = ["Model: \(status?.variant ?? "unknown")", ""]
        for entry in entries.reversed() {
            switch entry {
            case .run(let run):
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
                lines.append("Samples: \(run.result.sampleCount) · \(run.result.durationMs) ms")
                for answer in run.result.answers {
                    lines.append(Self.answerLine(answer, of: run.result.sampleCount))
                }
            case .sweep(let sweep):
                lines.append("Sweep: \(sweep.axis.rawValue) · held fixed — \(sweep.held)")
                for step in sweep.steps {
                    var label = step.label
                    if sweep.axis == .resolution, let w = step.sentWidth, let h = step.sentHeight {
                        label += " (\(w)×\(h))"
                    }
                    lines.append("  \(label)")
                    for answer in step.result.answers {
                        lines.append("  " + Self.answerLine(answer, of: step.result.sampleCount))
                    }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    private static func answerLine(_ answer: SampledAnswer, of total: Int) -> String {
        "  \(answer.count)/\(total)  \(String(format: "%.2f", answer.agreement))  \(answer.text)"
    }

    /// The closed answer set in force, or nil for free text.
    public var resolvedChoices: [String]? {
        switch shape {
        case .freeText:
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
        // Choices mode needs a usable set, otherwise Run would silently fall
        // back to free text and quietly change what is being measured.
        if shape == .choices, resolvedChoices == nil { return false }
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
            let sending = resolvedImage()
            let result = try await service.sample(
                prompt: prompt,
                images: sending.map { [$0.imageInput] } ?? [],
                instructions: trimmedInstructions.isEmpty ? nil : trimmedInstructions,
                samples: samples,
                choices: choices
            )
            entries.insert(.run(Run(
                    prompt: prompt,
                    instructions: trimmedInstructions.isEmpty ? nil : trimmedInstructions,
                    imageName: imageName,
                    choices: choices,
                    cropPixels: selection.flatMap { sel in image.map { $0.pixelRect(for: sel) } },
                    sentWidth: sending?.sentWidth,
                    sentHeight: sending?.sentHeight,
                    result: result,
                    at: Date()
                )),
                at: 0
            )
        } catch let error as InferenceError {
            failure = error.reason
        } catch {
            failure = "\(error)"
        }
    }

    public func removeEntry(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public func cancel() { cancelled = true }

    // MARK: Sweeps

    /// The values this sweep will step through, given the current state.
    public var sweepSteps: [String] {
        switch sweepAxis {
        case .resolution:
            guard let native = resolvedImageAtNativeSize() else { return [] }
            let longest = max(native.sentWidth, native.sentHeight)
            // Drop any ladder value close to the source's own size. A 257px crop
            // would otherwise be tested at 256 and 257 — one pixel apart, two
            // rows, the same experiment run twice.
            var dims = Self.sweepDimensions.filter {
                $0 < longest && Double(longest - $0) / Double(longest) >= 0.08
            }
            dims.append(longest)
            return dims.map { "\($0)px" }
        case .prompts:
            return promptVariants
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    /// The crop (or whole frame) at full available resolution, which sets the
    /// ceiling for a resolution sweep.
    private func resolvedImageAtNativeSize() -> LoadedImage? {
        guard let image else { return nil }
        let uncapped = max(image.originalWidth, image.originalHeight)
        guard let selection else { return try? image.resized(maxDimension: uncapped) }
        return try? image.cropped(to: selection, maxDimension: uncapped)
    }

    public var canSweep: Bool {
        guard !isRunning, sweepSteps.count >= 2 else { return false }
        if sweepAxis == .resolution,
           prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if shape == .choices, resolvedChoices == nil { return false }
        return true
    }

    public func sweep() async {
        guard canSweep else { return }
        isRunning = true
        cancelled = false
        failure = nil
        defer { isRunning = false; progress = nil }

        let axis = sweepAxis
        let labels = sweepSteps
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let choices = resolvedChoices
        // Snapshot the controls a sweep does not vary, so restoring them after is
        // exact and the card can state what was actually held fixed.
        let savedDimension = maxDimension
        let savedPrompt = prompt
        var steps: [Sweep.Step] = []

        for (index, label) in labels.enumerated() {
            if cancelled { break }
            progress = "\(index + 1) of \(labels.count) — \(label)"

            switch axis {
            case .resolution:
                maxDimension = Int(label.replacingOccurrences(of: "px", with: "")) ?? savedDimension
            case .prompts:
                prompt = label
            }

            guard let sending = resolvedImage() else { continue }
            do {
                let result = try await service.sample(
                    prompt: prompt,
                    images: [sending.imageInput],
                    instructions: trimmedInstructions.isEmpty ? nil : trimmedInstructions,
                    samples: samples,
                    choices: choices
                )
                steps.append(Sweep.Step(label: label,
                                        sentWidth: sending.sentWidth,
                                        sentHeight: sending.sentHeight,
                                        result: result))
            } catch let error as InferenceError {
                failure = error.reason
                break
            } catch {
                failure = "\(error)"
                break
            }
        }

        maxDimension = savedDimension
        prompt = savedPrompt

        guard !steps.isEmpty else { return }
        let held = axis == .resolution
            ? "prompt: \(savedPrompt)"
            : "sent at \(steps.first?.sentWidth ?? 0)×\(steps.first?.sentHeight ?? 0)"
        entries.insert(.sweep(Sweep(axis: axis, held: held, steps: steps, at: Date())), at: 0)
    }
}
