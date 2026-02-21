import Vapor
import Foundation
import FoundationModels

// MARK: - Request/Response Models

struct InferenceRequest: Content {
    let prompt: String
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case prompt
        case sessionId = "session_id"
    }
}

struct InferenceResponse: Content {
    let response: String
}

struct CreateSessionResponse: Content {
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
    }
}

struct DeleteSessionResponse: Content {
    let message: String
}

struct ErrorResponse: Content {
    let error: String
}

// MARK: - Error Middleware

struct JSONErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let abort as AbortError {
            let payload = ErrorResponse(error: abort.reason)
            let response = Response(status: abort.status)
            try response.content.encode(payload)
            return response
        } catch {
            request.logger.error("Unhandled error: \(error)")
            let payload = ErrorResponse(error: "\(error)")
            let response = Response(status: .internalServerError)
            try response.content.encode(payload)
            return response
        }
    }
}

// MARK: - Inference Service

actor InferenceService {
    private let model: SystemLanguageModel
    private var sessions: [String: LanguageModelSession] = [:]
    private var lastAccessed: [String: Date] = [:]

    init() {
        self.model = SystemLanguageModel.default
    }

    func checkAvailability() -> Bool {
        switch model.availability {
        case .available:
            return true
        default:
            return false
        }
    }

    func getAvailabilityMessage() -> String {
        switch model.availability {
        case .available:
            return "Model is available"
        case .unavailable(.deviceNotEligible):
            return "Device is not eligible for Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is not enabled in Settings"
        case .unavailable(.modelNotReady):
            return "Model is downloading or not ready yet"
        case .unavailable:
            return "Model is unavailable for unknown reason"
        @unknown default:
            return "Model availability unknown"
        }
    }

    func createSession() -> String {
        let id = UUID().uuidString
        sessions[id] = LanguageModelSession()
        lastAccessed[id] = Date()
        return id
    }

    func deleteSession(_ id: String) {
        sessions.removeValue(forKey: id)
        lastAccessed.removeValue(forKey: id)
    }

    func cleanupStaleSessions() {
        let cutoff = Date().addingTimeInterval(-30 * 60) // 30 minutes
        let staleIds = lastAccessed.filter { $0.value < cutoff }.map { $0.key }
        for id in staleIds {
            sessions.removeValue(forKey: id)
            lastAccessed.removeValue(forKey: id)
        }
    }

    func generateResponse(for prompt: String, sessionId: String? = nil) async throws -> String {
        guard checkAvailability() else {
            throw Abort(.serviceUnavailable, reason: getAvailabilityMessage())
        }

        let session: LanguageModelSession
        if let sessionId {
            guard let existing = sessions[sessionId] else {
                throw Abort(.notFound, reason: "Session not found: \(sessionId)")
            }
            session = existing
            lastAccessed[sessionId] = Date()
        } else {
            session = LanguageModelSession()
        }

        let response = try await session.respond(to: prompt)
        return response.content
    }
}

// MARK: - Application Setup

@main
struct App {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let logger = Logger(label: "App")
        let app = try await Application.make(env, .singleton, logger: logger)

        do {
            // Limits
            app.routes.defaultMaxBodySize = "1mb"

            // Middleware
            app.middleware.use(JSONErrorMiddleware())

            // Initialize inference service
            let inferenceService = InferenceService()

            // Background cleanup task — runs every 5 minutes
            let cleanupTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    await inferenceService.cleanupStaleSessions()
                }
            }

            // Configure routes
            app.post("inference") { req async throws -> InferenceResponse in
                let request = try req.content.decode(InferenceRequest.self)
                let response = try await inferenceService.generateResponse(
                    for: request.prompt,
                    sessionId: request.sessionId
                )
                return InferenceResponse(response: response)
            }

            // Session management
            app.post("sessions") { _ async -> CreateSessionResponse in
                let id = await inferenceService.createSession()
                return CreateSessionResponse(sessionId: id)
            }

            app.delete("sessions", ":sessionId") { req async throws -> DeleteSessionResponse in
                guard let sessionId = req.parameters.get("sessionId") else {
                    throw Abort(.badRequest, reason: "Missing session ID")
                }
                await inferenceService.deleteSession(sessionId)
                return DeleteSessionResponse(message: "Session deleted")
            }

            // Health check endpoint
            app.get("health") { _ in
                ["status": "ok"]
            }

            // Model status endpoint
            app.get("status") { _ async -> [String: String] in
                let isAvailable = await inferenceService.checkAvailability()
                let message = await inferenceService.getAvailabilityMessage()
                return [
                    "available": String(isAvailable),
                    "message": message
                ]
            }

            app.logger.info("Server starting on http://localhost:8080")
            app.logger.info("Try: curl -X POST http://localhost:8080/inference -H \"Content-Type: application/json\" -d '{\"prompt\":\"Hello\"}'")

            try await app.execute()
            cleanupTask.cancel()
        } catch {
            app.logger.error("Application error: \(error)")
            try await app.asyncShutdown()
            throw error
        }

        try await app.asyncShutdown()
    }
}
