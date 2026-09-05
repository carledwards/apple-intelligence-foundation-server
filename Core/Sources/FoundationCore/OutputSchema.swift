import Foundation
import FoundationModels

/// One field of a caller-defined output object.
public struct OutputField: Codable, Sendable, Equatable {
    public let name: String
    /// A scalar — `string`, `number`, `integer`, or `bool` — followed by any
    /// number of array suffixes. `[]` is a list of any length; `[N]` is a list
    /// of exactly N. Suffixes nest left to right, innermost first:
    /// `integer[4][]` is a list of four-integer lists — bounding boxes.
    public let type: String
    /// Sent to the model as the field's guide — the one place the semantics of
    /// a field are explained to it, so it carries the rule, not just the name.
    public let description: String?

    public static let scalarTypes = ["string", "number", "integer", "bool"]

    /// Whether `type` is well formed: a known scalar plus `[]` / `[N]` suffixes.
    public static func isValidType(_ type: String) -> Bool {
        var rest = Substring(type)
        while rest.hasSuffix("]") {
            guard let open = rest.lastIndex(of: "[") else { return false }
            let count = rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]
            guard count.isEmpty || (Int(count).map { $0 > 0 } ?? false) else { return false }
            rest = rest[..<open]
        }
        return scalarTypes.contains(String(rest))
    }

    public init(name: String, type: String, description: String? = nil) {
        self.name = name
        self.type = type
        self.description = description
    }
}

/// A flat object the model must produce, described by the caller at runtime.
///
/// This is guided generation: the framework enforces the structure and the
/// model supplies only the values. It never emits a brace or a quote. Prompted
/// JSON is assembled token by token instead, and this model sometimes puts a
/// reserved control token where a quote belongs — measured as the literal text
/// `<ctrl46>` in the output. A schema is the fix, not a better prompt.
public struct OutputSchema: Codable, Sendable, Equatable {
    public let fields: [OutputField]

    public init(fields: [OutputField]) {
        self.fields = fields
    }

    // MARK: Text form

    /// Parses one field per line, `name: type  description`, where the
    /// description is optional and runs to the end of the line. Blank lines
    /// are ignored. Throws `InferenceError.invalidRequest` naming the line.
    public static func parse(_ text: String) throws -> OutputSchema {
        var fields: [OutputField] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else {
                throw InferenceError.invalidRequest("Line \(index + 1): expected `name: type`")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let type = parts.first else {
                throw InferenceError.invalidRequest("Line \(index + 1): `\(name)` has no type")
            }
            let description = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces)
                : nil
            fields.append(OutputField(name: name, type: String(type), description: description))
        }
        let schema = OutputSchema(fields: fields)
        try schema.validate()
        return schema
    }

    /// The form `parse` reads.
    public var text: String {
        fields.map { field in
            var line = "\(field.name): \(field.type)"
            if let description = field.description, !description.isEmpty {
                line += "  \(description)"
            }
            return line
        }
        .joined(separator: "\n")
    }

    // MARK: Validation

    public func validate() throws {
        guard !fields.isEmpty else {
            throw InferenceError.invalidRequest("schema must have at least one field")
        }
        var seen = Set<String>()
        for field in fields {
            guard !field.name.isEmpty else {
                throw InferenceError.invalidRequest("schema field names must not be empty")
            }
            guard seen.insert(field.name).inserted else {
                throw InferenceError.invalidRequest("schema field `\(field.name)` is listed twice")
            }
            guard OutputField.isValidType(field.type) else {
                throw InferenceError.invalidRequest(
                    "schema field `\(field.name)` has unknown type `\(field.type)`; use \(OutputField.scalarTypes.joined(separator: ", ")), with [] for a list or [N] for a list of exactly N, e.g. integer[4][]"
                )
            }
        }
    }

    // MARK: Canonical form

    /// The same object with its keys in sorted order, compact. The framework
    /// emits fields in whatever order the model produced them, so two answers
    /// with identical values can differ as strings; sorting the keys makes
    /// equal objects equal text, which is what sampling compares. Values —
    /// including the order of items inside a list — are left exactly as
    /// generated. Returns the input unchanged if it is not JSON.
    public static func canonicalJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let sorted = try? JSONSerialization.data(
                  withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let string = String(data: sorted, encoding: .utf8) else { return text }
        return string
    }

    // MARK: Framework schema

    func generationSchema() throws -> GenerationSchema {
        try validate()
        let properties = fields.map { field in
            DynamicGenerationSchema.Property(
                name: field.name,
                description: field.description,
                schema: Self.schema(forType: field.type)
            )
        }
        do {
            return try GenerationSchema(
                root: DynamicGenerationSchema(name: "Output", properties: properties),
                dependencies: []
            )
        } catch {
            throw InferenceError.schemaConstructionFailed("Could not build a schema from fields: \(error)")
        }
    }

    /// The last suffix is the outermost array, so `integer[4][]` peels to a
    /// list of `integer[4]`, each a list of exactly four `integer`.
    private static func schema(forType type: String) -> DynamicGenerationSchema {
        if type.hasSuffix("]"), let open = type.lastIndex(of: "[") {
            let inner = String(type[..<open])
            let count = Int(type[type.index(after: open)..<type.index(before: type.endIndex)])
            return DynamicGenerationSchema(
                arrayOf: schema(forType: inner),
                minimumElements: count,
                maximumElements: count
            )
        }
        switch type {
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "bool": return DynamicGenerationSchema(type: Bool.self)
        default: return DynamicGenerationSchema(type: String.self)
        }
    }
}
