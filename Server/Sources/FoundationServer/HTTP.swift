import Vapor
import FoundationCore

// MARK: - Wire conformances
//
// The core types are plain Codable so they can be linked by a UI target. Vapor's
// Content conformance is added here, on the HTTP side of the boundary.

extension ImageInput: @retroactive Content {}
extension InferenceRequest: @retroactive Content {}
extension InferenceResponse: @retroactive Content {}
extension StatusResponse: @retroactive Content {}
extension ClassifyRequest: @retroactive Content {}
extension ClassifiedSubject: @retroactive Content {}
extension ClassifyResponse: @retroactive Content {}
extension ContextUsage: @retroactive Content {}

// MARK: - HTTP-only payloads

/// Optional body on `POST /sessions`. The route still accepts no body at all.
struct CreateSessionRequest: Content {
    let instructions: String?
}

struct CreateSessionResponse: Content {
    let sessionId: String
    /// Echoed back so a caller can confirm what the session was created with.
    let instructions: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case instructions
    }

    /// Written explicitly so `instructions` is always present, `null` when unset,
    /// rather than vanishing from the response and turning a client's key lookup
    /// into an error.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(instructions, forKey: .instructions)
    }
}

struct DeleteSessionResponse: Content {
    let message: String
}

struct ErrorResponse: Content {
    let error: String
}

/// Asks what a prompt would cost without spending it.
struct TokenCountRequest: Content {
    let prompt: String
    let images: [ImageInput]?
}

struct TokenCountResponse: Content {
    let tokens: Int
    let contextSize: Int

    enum CodingKeys: String, CodingKey {
        case tokens
        case contextSize = "context_size"
    }
}

// MARK: - Error Middleware

/// Turns every thrown error into the same JSON shape. `InferenceError` carries
/// its own status so the mapping is one line rather than a switch that has to be
/// kept in step with the enum.
struct JSONErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let inference as InferenceError {
            return try encode(ErrorResponse(error: inference.reason),
                              status: HTTPResponseStatus(statusCode: inference.statusCode))
        } catch let abort as AbortError {
            return try encode(ErrorResponse(error: abort.reason), status: abort.status)
        } catch {
            request.logger.error("Unhandled error: \(error)")
            return try encode(ErrorResponse(error: "\(error)"), status: .internalServerError)
        }
    }

    private func encode(_ payload: ErrorResponse, status: HTTPResponseStatus) throws -> Response {
        let response = Response(status: status)
        try response.content.encode(payload)
        return response
    }
}
