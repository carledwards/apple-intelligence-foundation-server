import Foundation

/// Everything this package throws. Replaces Vapor's `Abort` so the model layer
/// carries no HTTP dependency and can be linked by an app target.
///
/// `statusCode` is still an HTTP status. That is a deliberate concession rather
/// than a leak: the JSONL log records the status the caller saw, and keeping one
/// log schema across the server and any app built on this package is worth more
/// than purity. A UI client can ignore it and switch on the case instead.
public enum InferenceError: Error, Sendable {
    /// Apple Intelligence is off, still downloading, or the device is ineligible.
    case modelUnavailable(String)
    /// The current model variant cannot accept image input.
    case visionUnsupported
    case sessionNotFound(String)
    /// A response is already in flight on this session.
    case sessionBusy(String)
    /// Caller-supplied arguments are contradictory or out of range.
    case invalidRequest(String)
    case imageDecodingFailed(String)
    case schemaConstructionFailed(String)
    /// Every sample came back empty — the model returned nothing to tally.
    case emptyClassification
    /// The session's transcript no longer fits the model's context window.
    /// Not a bug to be hidden: it is the constraint a caller most needs to see,
    /// so both numbers are carried out rather than collapsed into a message.
    case contextSizeExceeded(used: Int, limit: Int)
    /// The safety system declined the prompt or the generated answer. A normal
    /// outcome when probing a model, not a server fault.
    case contentRefused(String)
    case rateLimited
    /// Private Cloud Compute declined the request because the app's quota is
    /// spent. Carries the framework's message, which names the reset window.
    case quotaExceeded(String)
    case timedOut
    case logUnavailable(String)

    public var reason: String {
        switch self {
        case .modelUnavailable(let message):
            return message
        case .visionUnsupported:
            return "The current model variant does not accept image input"
        case .sessionNotFound(let id):
            return "Session not found: \(id)"
        case .sessionBusy(let id):
            return "Session \(id) is already handling a request. Requests sharing a session must be sequential"
        case .invalidRequest(let message):
            return message
        case .imageDecodingFailed(let message):
            return message
        case .schemaConstructionFailed(let message):
            return message
        case .emptyClassification:
            return "Classification produced no result"
        case .contextSizeExceeded(let used, let limit):
            return "Context exhausted: \(used) tokens used of \(limit). Reset this session or start a new one"
        case .contentRefused(let message):
            return message
        case .rateLimited:
            return "The model is rate limited. Retry shortly"
        case .quotaExceeded(let message):
            return message
        case .timedOut:
            return "The model timed out"
        case .logUnavailable(let message):
            return message
        }
    }

    public var statusCode: Int {
        switch self {
        case .modelUnavailable: return 503
        case .visionUnsupported: return 400
        case .sessionNotFound: return 404
        case .sessionBusy: return 409
        case .invalidRequest: return 400
        case .imageDecodingFailed: return 400
        case .schemaConstructionFailed: return 400
        case .emptyClassification: return 500
        // 413 Content Too Large: the request could not be carried because the
        // accumulated conversation no longer fits, not because it was malformed.
        case .contextSizeExceeded: return 413
        // 422: the request was well formed, the model declined to act on it.
        case .contentRefused: return 422
        case .rateLimited: return 429
        case .quotaExceeded: return 429
        case .timedOut: return 504
        case .logUnavailable: return 500
        }
    }
}

extension InferenceError: LocalizedError {
    public var errorDescription: String? { reason }
}
