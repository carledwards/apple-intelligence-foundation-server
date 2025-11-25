import Vapor
import Foundation
import FoundationModels

// MARK: - Request/Response Models

struct InferenceRequest: Content {
    let prompt: String
}

struct InferenceResponse: Content {
    let response: String
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
            let payload = ErrorResponse(error: "Internal server error")
            let response = Response(status: .internalServerError)
            try response.content.encode(payload)
            return response
        }
    }
}

// MARK: - Inference Service

actor InferenceService {
    private let model: SystemLanguageModel
    
    init() {
        // Get the system language model
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
    
    func generateResponse(for prompt: String) async throws -> String {
        // Check if model is available
        guard checkAvailability() else {
            throw Abort(.serviceUnavailable, reason: getAvailabilityMessage())
        }
        
        // Create a new session for this request
        let session = LanguageModelSession()
        
        // Generate response using Foundation Models
        let response = try await session.respond(to: prompt)
        
        // Extract the string content from the response
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

            // Configure routes
            app.post("inference") { req async throws -> InferenceResponse in
                let request = try req.content.decode(InferenceRequest.self)
                let response = try await inferenceService.generateResponse(for: request.prompt)
                return InferenceResponse(response: response)
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
        } catch {
            app.logger.error("Application error: \(error)")
            try await app.asyncShutdown()
            throw error
        }
        
        try await app.asyncShutdown()
    }
}
