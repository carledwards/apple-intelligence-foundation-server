import Foundation
import Observation
import CoreGraphics
import Vision
import FoundationCore

/// A circle on the photo: where the subject is, and how tight. Fractions, so it survives any
/// resize and exports straight into the Looking Back harness ("cx cy r").
public struct CircleCrop: Equatable, Sendable {
    /// Center, 0–1 across width and height.
    public var cx: Double = 0.5
    public var cy: Double = 0.5
    /// 1 = the whole shorter side; 4 = a quarter of it.
    public var zoom: Double = 1

    /// Radius as a fraction of the shorter side.
    public var r: Double { 0.5 / zoom }

    /// The bounding square of the circle, in the 0–1 coordinates `LoadedImage.cropped` takes.
    public func normalizedRect(width: Int, height: Int) -> CGRect {
        let w = Double(width), h = Double(height)
        let side = min(w, h) / zoom
        let x = min(max(cx * w - side / 2, 0), w - side)
        let y = min(max(cy * h - side / 2, 0), h - side)
        return CGRect(x: x / w, y: y / h, width: side / w, height: side / h)
    }

    public var isWholeFrame: Bool { zoom <= 1.001 }

    /// "0.72 0.35 0.2", three decimals.
    public var exportText: String {
        String(format: "%.3f %.3f %.3f", cx, cy, r)
    }
}

/// What the model said about one photo, twice: the whole frame for context, the crop for
/// the subject. Kept together so the comparison is on screen, not in your head.
public struct VisionLabel: Sendable, Hashable {
    public let label: String
    public let confidence: Double
}

/// What Apple's Vision framework says, no language model involved: animals by name, then the
/// scene classifier's top labels. Deterministic and free, which is why it sits beside the
/// model: the question is which one to trust for what.
public enum VisionPass {
    public static func labels(in image: CGImage, top: Int = 6, floor: Double = 0.3) -> [VisionLabel] {
        var found: [VisionLabel] = []
        let animals = VNRecognizeAnimalsRequest()
        let scene = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([animals, scene])
        for result in animals.results ?? [] {
            for label in result.labels where Double(label.confidence) >= floor {
                let word = label.identifier.lowercased()
                if !found.contains(where: { $0.label == word }) { found.append(VisionLabel(label: word, confidence: Double(label.confidence))) }
            }
        }
        for result in (scene.results ?? []).sorted(by: { $0.confidence > $1.confidence }) where Double(result.confidence) >= floor {
            let word = result.identifier.lowercased().replacingOccurrences(of: "_", with: " ")
            if !found.contains(where: { $0.label == word }) { found.append(VisionLabel(label: word, confidence: Double(result.confidence))) }
            if found.count >= top { break }
        }
        return found
    }
}

/// Words in the picture, and what they tell us. Vision reads the text off the full-resolution
/// original; the model then reads the words, not the picture, and names the place (with its
/// country when it can be inferred), the people, the dates, and the occasion. A signpost
/// says "Zermatt"; the model says Switzerland.
public struct TextFacts: Sendable {
    public struct Line: Sendable, Hashable { public let text: String; public let confidence: Double }
    public let lines: [Line]
    /// The place as written: "Hörnlihütte", "The Gem State".
    public var place: String?
    /// Where that is: "Zermatt, Switzerland", "Idaho, USA". The model's inference, from the
    /// language and the names; the field the app would actually use.
    public var region: String?
    public var names: [String] = []
    public var dates: [String] = []
    /// "beloved wife, mother and grandmother": who the person was to the writer.
    public var relationship: String?
    public var occasion: String?
    public let durationMs: Int

    public var hasAnything: Bool { !lines.isEmpty }
    public var reading: String {
        var parts: [String] = []
        if let place, !place.isEmpty { parts.append("place: \(place)" + (region.map { " (\($0))" } ?? "")) }
        else if let region, !region.isEmpty { parts.append("place: \(region)") }
        if !names.isEmpty { parts.append("names: \(names.joined(separator: ", "))") }
        if !dates.isEmpty { parts.append("dates: \(dates.joined(separator: ", "))") }
        if let relationship, !relationship.isEmpty { parts.append("relationship: \(relationship)") }
        if let occasion, !occasion.isEmpty { parts.append("occasion: \(occasion)") }
        return parts.joined(separator: " · ")
    }

    /// Guards on the model's fields, since a schema forces a value into every slot: a date
    /// must contain a year, a place must not be a military branch or a slogan, and names
    /// that were read as one word per line ("WILLIAM", "LEE", "EDWARDS") become one name.
    static func cleaned(place: String?, region: String?, names: [String], dates: [String], relationship: String?, occasion: String?, lines: [Line]) -> (String?, String?, [String], [String], String?, String?) {
        // The model writes the word "empty" into a field it was told to leave empty.
        func empty(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
                  !["empty", "none", "n/a", "unknown", "null"].contains(s.lowercased()) else { return nil }
            return s
        }
        let year = try! Regex(#"\b(1[89]|20)\d{2}\b"#)
        // Dates: the lines themselves are the record. A line that reads as a full date ("JUL 19
        // 1928") beats the model's shortening of it ("1928").
        let fullDate = try! Regex(#"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2},?\s+(1[89]|20)\d{2}\b|\b\d{1,2}/\d{1,2}/(1[89]|20)\d{2}\b"#)
        let lineDates = lines.compactMap { line in line.text.firstMatch(of: fullDate).map { String(line.text[$0.range]) } }
        let goodDates = lineDates.isEmpty ? dates.filter { $0.contains(year) } : lineDates
        // Names: merge runs of single capitalized words that sit on consecutive lines.
        var merged: [String] = []
        let words = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lineTexts = lines.map(\.text)
        var i = 0
        while i < words.count {
            var run = [words[i]]
            var j = i + 1
            while j < words.count, words[j].split(separator: " ").count == 1,
                  let a = lineTexts.firstIndex(of: words[j - 1]), let b = lineTexts.firstIndex(of: words[j]), b == a + 1 {
                run.append(words[j]); j += 1
            }
            merged.append(run.joined(separator: " ")); i = j
        }
        let placeText = empty(place).flatMap { p -> String? in
            let lower = p.lowercased()
            return ["coast guard", "army", "navy", "air force", "marine", "beloved"].contains(where: lower.contains) ? nil : p
        }
        return (placeText, empty(region), merged, goodDates, empty(relationship), empty(occasion))
    }
}

public enum TextPass {
    /// Every line Vision can read, best candidate each, above a low bar. Full resolution: text
    /// is the one thing that gets better with more pixels.
    public static func lines(in image: CGImage) -> [TextFacts.Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, Double(best.confidence) >= 0.3 else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespaces)
            return text.count >= 2 ? TextFacts.Line(text: text, confidence: Double(best.confidence)) : nil
        }
    }

    static let schema = try? OutputSchema.parse("""
        place: string  a place name written in the text, as written, or empty if the text names no place
        region: string  where that place is, as a region and country you infer from the name or the language, such as "Zermatt, Switzerland" for Hörnlihütte or "Idaho, USA" for The Gem State, or empty
        names: string[]  people's full names written in the text, each as one entry
        dates: string[]  dates or years written in the text, each with its year
        relationship: string  what the text says a person was to the writer, such as "beloved wife, mother and grandmother", or empty
        occasion: string  the occasion the text points to, such as a graduation, a wedding, a memorial, or empty
        """)
}

public struct PhotoVerdict: Sendable {
    public let fullSubjects: [ClassifiedSubject]
    public let cropSubjects: [ClassifiedSubject]?
    public let fullVision: [VisionLabel]
    public let cropVision: [VisionLabel]?
    public let sentence: String
    public let cropSentence: String?
    public let sentFull: (Int, Int)
    public let sentCrop: (Int, Int)?
    public let crop: CircleCrop
    /// The "send at" size this verdict was produced with.
    public let size: Int
    public let durationMs: Int
    public let at: Date
}

@MainActor
@Observable
public final class PhotoItem: Identifiable {
    public let id = UUID()
    public let name: String
    public let image: LoadedImage
    public var crop = CircleCrop()
    /// One verdict per send size. A single size is the common case; "All" fills several.
    public internal(set) var verdicts: [Int: PhotoVerdict] = [:]
    public internal(set) var isRunning = false
    public internal(set) var failure: String?
    /// Your own words, exported as the harness's notes column.
    public var notes: String = ""
    public internal(set) var text: TextFacts?
    public internal(set) var isReadingText = false

    init(name: String, image: LoadedImage) {
        self.name = name
        self.image = image
    }

    /// The crop cut from the full-resolution original, at the batch's send size.
    func croppedImage(maxDimension: Int) -> LoadedImage? {
        try? image.cropped(to: crop.normalizedRect(width: image.originalWidth, height: image.originalHeight), maxDimension: maxDimension)
    }

    /// The verdict the column and the export lead with: the largest size run.
    public var verdict: PhotoVerdict? {
        verdicts.keys.max().flatMap { verdicts[$0] }
    }

    public var sizesRun: [Int] { verdicts.keys.sorted() }

    /// Stale when the crop moved since the last run.
    public var isStale: Bool {
        guard let verdict else { return true }
        return verdict.crop != crop
    }
}

/// The batch: many photos, one circle each, the model re-run as circles move, and an export
/// the Looking Back photo harness reads as its labels file.
@MainActor
@Observable
public final class PhotoBatchModel {
    private let service: InferenceService

    public private(set) var items: [PhotoItem] = []
    public var selectedID: UUID?
    public var checked: Set<UUID> = []

    /// The closed set the model answers from. Keep competitors in; "none" is the escape hatch.
    public var classesText = "person, pet, vehicle, home, food, scenery, none"
    public var samples = 3
    public var maxLabels = 3
    /// The send sizes to run, one verdict each. One is the common case; several is a sweep,
    /// which multiplies the run by the number of sizes, so use it sparingly.
    public var selectedSizes: Set<Int> = [1024]
    public static let dimensionChoices = [384, 512, 768, 1024, 1536]
    public var sizesToRun: [Int] { selectedSizes.isEmpty ? [1024] : selectedSizes.sorted() }

    public func toggleSize(_ size: Int) {
        if selectedSizes.contains(size), selectedSizes.count > 1 { selectedSizes.remove(size) } else { selectedSizes.insert(size) }
    }

    public var sizesLabel: String {
        let sizes = sizesToRun
        if sizes.count == Self.dimensionChoices.count { return "All sizes" }
        return sizes.map(String.init).joined(separator: ", ") + " px"
    }
    public var sentencePrompt = "Describe this photo in one short sentence, naming what is in it."
    public var hint = ""
    /// Re-run a photo automatically when its circle moves.
    public var runOnChange = true
    /// Read the text in every photo as part of a run. Off by default: most photos have none,
    /// and it is a pass you reach for on the few that do.
    public var readTextOnRun = false
    public var selectedModel: ModelChoice = .onDevice
    public private(set) var status: [ModelChoice: StatusResponse] = [:]
    public private(set) var queued: Set<UUID> = []
    public private(set) var runningCount = 0
    private var pending: Task<Void, Never>?

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

    public var availableModels: [ModelChoice] {
        ModelChoice.allCases.filter { status[$0]?.available ?? true }
    }

    public var classes: [String] {
        classesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    public var selected: PhotoItem? { items.first { $0.id == selectedID } }

    // MARK: Photos

    public func add(urls: [URL]) {
        for url in urls {
            guard let image = try? ImageLoading.load(contentsOf: url) else { continue }
            let item = PhotoItem(name: url.lastPathComponent, image: image)
            items.append(item)
            if selectedID == nil { selectedID = item.id }
            if runOnChange { schedule(item) }
        }
    }

    public func add(data: Data, name: String) {
        guard let image = try? ImageLoading.load(data) else { return }
        let item = PhotoItem(name: name, image: image)
        items.append(item)
        if selectedID == nil { selectedID = item.id }
        if runOnChange { schedule(item) }
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        checked.remove(id)
        queued.remove(id)
        if selectedID == id { selectedID = items.first?.id }
    }

    /// Called as a circle moves. Debounced, so dragging doesn't fire a run per pixel.
    public func cropChanged(_ item: PhotoItem) {
        guard runOnChange else { return }
        pending?.cancel()
        let id = item.id
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, let item = self.items.first(where: { $0.id == id }) else { return }
            self.schedule(item)
        }
    }

    public func runAll(onlyStale: Bool = true) {
        for item in items where !onlyStale || item.isStale { schedule(item) }
    }

    // MARK: Running

    /// One photo at a time keeps the on-device model responsive; a photo whose circle moves
    /// again while queued is simply run with its latest circle.
    public func schedule(_ item: PhotoItem) {
        guard !queued.contains(item.id) else { return }
        queued.insert(item.id)
        Task { await drain() }
    }

    private var draining = false
    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while let id = queued.first, let item = items.first(where: { $0.id == id }) {
            queued.remove(id)
            await run(item)
        }
        queued.removeAll()
    }

    private func run(_ item: PhotoItem) async {
        item.isRunning = true
        item.failure = nil
        runningCount += 1
        defer { item.isRunning = false; runningCount -= 1 }
        if readTextOnRun, item.text == nil { await readText(item) }
        let crop = item.crop
        let sizes = sizesToRun
        // A size no longer selected drops out, so the column and the summary show this run only.
        item.verdicts = item.verdicts.filter { sizes.contains($0.key) }
        for size in sizes {
        let started = Date()
        do {
            let classes = self.classes
            guard classes.count >= 2 else { throw InferenceError.invalidRequest("Give at least two classes.") }
            let full = try item.image.resized(maxDimension: size)
            let fullVision = VisionPass.labels(in: full.display)
            let hintText = hint.trimmingCharacters(in: .whitespaces)
            let fullVerdict = try await service.classify(ClassifyRequest(
                classes: classes, images: [full.imageInput], hint: hintText.isEmpty ? nil : hintText,
                samples: samples, maxLabels: maxLabels, model: selectedModel))
            var cropVerdict: ClassifyResponse? = nil
            var cropSentence: String? = nil
            var cropVision: [VisionLabel]? = nil
            var cut: LoadedImage? = nil
            if !crop.isWholeFrame, let cropped = item.croppedImage(maxDimension: size) {
                cut = cropped
                cropVision = VisionPass.labels(in: cropped.display)
                cropVerdict = try await service.classify(ClassifyRequest(
                    classes: classes, images: [cropped.imageInput], hint: hintText.isEmpty ? nil : hintText,
                    samples: samples, maxLabels: maxLabels, model: selectedModel))
                cropSentence = try await service.generateResponse(
                    for: sentencePrompt, newSession: true, images: [cropped.imageInput], model: selectedModel).response
            }
            let sentence = try await service.generateResponse(
                for: sentencePrompt, newSession: true, images: [full.imageInput], model: selectedModel).response
            item.verdicts[size] = PhotoVerdict(
                fullSubjects: fullVerdict.subjects,
                cropSubjects: cropVerdict?.subjects,
                fullVision: fullVision,
                cropVision: cropVision,
                sentence: sentence.trimmingCharacters(in: .whitespacesAndNewlines),
                cropSentence: cropSentence?.trimmingCharacters(in: .whitespacesAndNewlines),
                sentFull: (full.sentWidth, full.sentHeight),
                sentCrop: cut.map { ($0.sentWidth, $0.sentHeight) },
                crop: crop,
                size: size,
                durationMs: Int(Date().timeIntervalSince(started) * 1000),
                at: Date())
        } catch let error as InferenceError {
            item.failure = error.reason
            break
        } catch {
            item.failure = "\(error)"
            break
        }
        }
    }

    /// Read the words in one photo and ask the model what they tell us. Independent of the
    /// classification runs, so it can be done on a photo that is interesting without re-running.
    public func readText(_ item: PhotoItem) async {
        item.isReadingText = true
        defer { item.isReadingText = false }
        let started = Date()
        let lines = TextPass.lines(in: item.image.original)
        var facts = TextFacts(lines: lines, durationMs: 0)
        if !lines.isEmpty, let schema = TextPass.schema {
            let prompt = "Text read from a photo, one line per piece:\n" + lines.map(\.text).joined(separator: "\n")
            if let response = try? await service.generateResponse(
                for: prompt, newSession: true,
                instructions: "You read text that was found in a photo, such as a sign, a headstone, or a banner, and say what it tells us. A place may be written as a nickname or in another language; say where it is. A military branch or a slogan is not a place. Leave a field empty when the text does not say.",
                model: selectedModel, schema: schema).response,
               let data = response.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let (place, region, names, dates, relationship, occasion) = TextFacts.cleaned(
                    place: object["place"] as? String, region: object["region"] as? String,
                    names: (object["names"] as? [String]) ?? [], dates: (object["dates"] as? [String]) ?? [],
                    relationship: object["relationship"] as? String, occasion: object["occasion"] as? String, lines: lines)
                facts.place = place; facts.region = region; facts.names = names; facts.dates = dates
                facts.relationship = relationship; facts.occasion = occasion
            }
        }
        item.text = TextFacts(lines: facts.lines, place: facts.place, region: facts.region, names: facts.names, dates: facts.dates,
                              relationship: facts.relationship, occasion: facts.occasion,
                              durationMs: Int(Date().timeIntervalSince(started) * 1000))
    }

    // MARK: Export

    /// The app's four kinds, decided from the crop when there is one, else the frame:
    /// labels at agreement ≥ 0.67, "none" only when nothing else made it. A species or a
    /// specific thing counts as its kind, so a class list with "cat" and "truck" in it still
    /// exports as pet and vehicle.
    public static let appKinds = ["person", "pet", "vehicle", "home"]

    public static func kind(of label: String) -> String? {
        switch label {
        case "person", "people", "man", "woman", "child", "baby", "kid", "boy", "girl", "face": return "person"
        case "pet", "animal", "cat", "kitten", "dog", "puppy", "horse", "pony", "bird", "rabbit", "bunny", "hamster", "fish", "goat", "chicken": return "pet"
        case "vehicle", "car", "truck", "pickup", "van", "suv", "motorcycle", "bus", "boat", "bicycle", "bike", "jeep": return "vehicle"
        case "home", "house", "apartment", "building", "room", "kitchen", "living room", "bedroom", "backyard", "yard", "garage": return "home"
        default: return nil
        }
    }

    public func kinds(for item: PhotoItem) -> [String] {
        guard let verdict = item.verdict else { return [] }
        let subjects = verdict.cropSubjects ?? verdict.fullSubjects
        var kinds: [String] = []
        for subject in subjects where subject.agreement >= 0.67 {
            if let kind = Self.kind(of: subject.label), !kinds.contains(kind) { kinds.append(kind) }
        }
        return kinds.isEmpty ? ["none"] : kinds
    }

    private var exportItems: [PhotoItem] {
        checked.isEmpty ? items : items.filter { checked.contains($0.id) }
    }

    /// labels.csv as the Looking Back photo harness reads it: file,kinds,notes,crop.
    /// The model's kinds are a starting point; correct them before trusting the file.
    public var csv: String {
        var lines = ["file,kinds,notes,crop"]
        for item in exportItems {
            let notes = item.notes.isEmpty ? (item.verdict?.sentence ?? "") : item.notes
            let quoted = "\"" + notes.replacingOccurrences(of: "\"", with: "'") + "\""
            let crop = item.crop.isWholeFrame ? "" : item.crop.exportText
            lines.append("\(item.name),\(kinds(for: item).joined(separator: "|")),\(quoted),\(crop)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One report across every photo that has run: a row per photo, then the totals that show
    /// where a class list or a hint is going wrong. Change one thing, re-run, compare two of these.
    public var summary: String {
        let ran = items.filter { $0.verdict != nil }
        var out: [String] = []
        out.append("# Photos summary")
        out.append("")
        out.append("\(ran.count) of \(items.count) photos run · classes: \(classes.joined(separator: ", ")) · samples \(samples) · send \(sizesLabel)"
                   + (hint.isEmpty ? "" : " · hint: \(hint)"))
        out.append("")
        out.append("| photo | circle | frame (model) | circle (model) | vision frame | vision circle | exports | ms |")
        out.append("|---|---|---|---|---|---|---|---|")
        func votes(_ s: [ClassifiedSubject]) -> String { s.map { "\($0.label) \($0.votes)/\(samples)" }.joined(separator: ", ") }
        func seen(_ s: [VisionLabel]) -> String { s.prefix(3).map { "\($0.label) \(String(format: "%.2f", $0.confidence))" }.joined(separator: ", ") }
        for item in ran {
            let v = item.verdict!
            out.append("| \(item.name) | \(item.crop.isWholeFrame ? "whole" : item.crop.exportText) | \(votes(v.fullSubjects)) | \(v.cropSubjects.map(votes) ?? "–") | \(seen(v.fullVision)) | \(v.cropVision.map(seen) ?? "–") | \(kinds(for: item).joined(separator: "|")) | \(v.durationMs) |")
        }
        out.append("")
        out.append("## Sentences")
        out.append("")
        for item in ran {
            let v = item.verdict!
            out.append("- **\(item.name)**: \(v.sentence)" + (v.cropSentence.map { " · circle: \($0)" } ?? "") + (item.notes.isEmpty ? "" : " · truth: \(item.notes)"))
        }

        let withText = items.filter { $0.text?.hasAnything == true }
        if !withText.isEmpty {
            out.append("")
            out.append("## Text")
            out.append("")
            for item in withText {
                let t = item.text!
                out.append("- **\(item.name)** (\(t.lines.count) lines): " + (t.reading.isEmpty ? "nothing inferred" : t.reading))
                out.append("  - " + t.lines.prefix(8).map { "\"\($0.text)\"" }.joined(separator: " · "))
            }
        }

        // Totals: how often each label wins, and with what agreement, frame vs circle.
        var frameCount: [String: Int] = [:], frameAgree: [String: Double] = [:]
        var circleCount: [String: Int] = [:], circleAgree: [String: Double] = [:]
        var circled = 0, disagreements: [String] = [], visionMatches = 0, visionMisses = 0
        for item in ran {
            let v = item.verdict!
            for s in v.fullSubjects { frameCount[s.label, default: 0] += 1; frameAgree[s.label, default: 0] += s.agreement }
            if let c = v.cropSubjects {
                circled += 1
                for s in c { circleCount[s.label, default: 0] += 1; circleAgree[s.label, default: 0] += s.agreement }
                let frameKinds = Set(v.fullSubjects.filter { $0.agreement >= 0.67 }.compactMap { Self.kind(of: $0.label) })
                let circleKinds = Set(c.filter { $0.agreement >= 0.67 }.compactMap { Self.kind(of: $0.label) })
                if frameKinds != circleKinds {
                    disagreements.append("\(item.name): frame \(frameKinds.sorted().joined(separator: "|").isEmpty ? "none" : frameKinds.sorted().joined(separator: "|")) vs circle \(circleKinds.sorted().joined(separator: "|").isEmpty ? "none" : circleKinds.sorted().joined(separator: "|"))")
                }
            }
            // Vision vs model on the exported kind: does Vision's best guess land in the same kind?
            let modelKinds = Set(kinds(for: item))
            let visionKinds = Set((v.cropVision ?? v.fullVision).compactMap { Self.kind(of: $0.label) })
            if modelKinds == ["none"] && visionKinds.isEmpty { visionMatches += 1 }
            else if !modelKinds.isDisjoint(with: visionKinds) { visionMatches += 1 }
            else { visionMisses += 1 }
        }
        out.append("")
        out.append("## Totals")
        out.append("")
        out.append("| label | frame: photos | frame: mean agreement | circle: photos | circle: mean agreement |")
        out.append("|---|---|---|---|---|")
        for label in classes {
            let f = frameCount[label, default: 0], c = circleCount[label, default: 0]
            let fa = f > 0 ? String(format: "%.2f", frameAgree[label, default: 0] / Double(f)) : "–"
            let ca = c > 0 ? String(format: "%.2f", circleAgree[label, default: 0] / Double(c)) : "–"
            out.append("| \(label) | \(f)/\(ran.count) | \(fa) | \(c)/\(circled) | \(ca) |")
        }
        out.append("")
        out.append("Frame and circle disagree on the kind in \(disagreements.count) of \(circled) circled photos" + (disagreements.isEmpty ? "." : ":"))
        for line in disagreements { out.append("- \(line)") }
        out.append("")
        out.append("Vision agrees with the exported kind on \(visionMatches) of \(ran.count) photos, disagrees on \(visionMisses).")
        if !ran.isEmpty {
            let ms = ran.map { $0.verdict!.durationMs }.reduce(0, +) / ran.count
            out.append("")
            out.append("Mean \(ms) ms per photo at \(ran.first!.verdict!.size) px.")
        }

        // A sweep: the same totals at every size, so the floor shows as a row that changes.
        let sizes = Set(ran.flatMap { $0.sizesRun }).sorted()
        if sizes.count > 1 {
            out.append("")
            out.append("## By send size")
            out.append("")
            out.append("| photo | " + sizes.map { "\($0) px" }.joined(separator: " | ") + " |")
            out.append("|---|" + sizes.map { _ in "---" }.joined(separator: "|") + "|")
            for item in ran {
                let cells = sizes.map { size -> String in
                    guard let v = item.verdicts[size] else { return "–" }
                    let subjects = v.cropSubjects ?? v.fullSubjects
                    let kinds = subjects.filter { $0.agreement >= 0.67 }.map { "\($0.label) \($0.votes)/\(samples)" }
                    return kinds.isEmpty ? "none" : kinds.joined(separator: ", ")
                }
                out.append("| \(item.name) | " + cells.joined(separator: " | ") + " |")
            }
            out.append("")
            out.append("| label | " + sizes.map { "\($0) px" }.joined(separator: " | ") + " |")
            out.append("|---|" + sizes.map { _ in "---" }.joined(separator: "|") + "|")
            for label in classes {
                let cells = sizes.map { size -> String in
                    let hits = ran.compactMap { $0.verdicts[size] }.compactMap { v in (v.cropSubjects ?? v.fullSubjects).first { $0.label == label } }
                    guard !hits.isEmpty else { return "–" }
                    return "\(hits.count) · \(String(format: "%.2f", hits.map(\.agreement).reduce(0, +) / Double(hits.count)))"
                }
                out.append("| \(label) | " + cells.joined(separator: " | ") + " |")
            }
            out.append("")
            out.append("Cells: photos where the label appeared (circle when there is one, else frame) · mean agreement.")
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Everything, for anyone who wants the raw votes.
    public var json: String {
        struct Out: Encodable {
            struct Subject: Encodable { let label: String; let votes: Int; let agreement: Double }
            struct Seen: Encodable { let label: String; let confidence: Double }
            let file: String; let crop: String?; let kinds: [String]; let notes: String
            struct Run: Encodable {
                let size: Int; let full: [Subject]; let cropSubjects: [Subject]?; let sentence: String; let cropSentence: String?
                let vision: [Seen]; let cropVision: [Seen]?; let sent: String; let durationMs: Int
            }
            struct Text: Encodable { let lines: [String]; let place: String?; let region: String?; let names: [String]; let dates: [String]; let relationship: String?; let occasion: String? }
            let runs: [Run]
            let text: Text?
        }
        let rows = exportItems.map { item -> Out in
            func subs(_ s: [ClassifiedSubject]?) -> [Out.Subject]? { s?.map { .init(label: $0.label, votes: $0.votes, agreement: $0.agreement) } }
            func seen(_ s: [VisionLabel]?) -> [Out.Seen]? { s?.map { .init(label: $0.label, confidence: $0.confidence) } }
            let runs = item.sizesRun.compactMap { item.verdicts[$0] }.map { v in
                Out.Run(size: v.size, full: subs(v.fullSubjects) ?? [], cropSubjects: subs(v.cropSubjects), sentence: v.sentence, cropSentence: v.cropSentence,
                        vision: seen(v.fullVision) ?? [], cropVision: seen(v.cropVision),
                        sent: "\(v.sentFull.0)x\(v.sentFull.1)" + (v.sentCrop.map { " crop \($0.0)x\($0.1)" } ?? ""), durationMs: v.durationMs)
            }
            let text = item.text.map { Out.Text(lines: $0.lines.map(\.text), place: $0.place, region: $0.region, names: $0.names, dates: $0.dates, relationship: $0.relationship, occasion: $0.occasion) }
            return Out(file: item.name, crop: item.crop.isWholeFrame ? nil : item.crop.exportText, kinds: kinds(for: item), notes: item.notes, runs: runs, text: text)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(rows), encoding: .utf8)) ?? "[]"
    }
}
