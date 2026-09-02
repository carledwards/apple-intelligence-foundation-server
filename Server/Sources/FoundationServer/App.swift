import Vapor
import FoundationCore

@main
struct App {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let logger = Logger(label: "App")
        let app = try await Application.make(env, .singleton, logger: logger)

        do {
            // Limits — generous enough for base64-encoded images, which inflate
            // the payload by roughly 4/3 over the raw bytes.
            app.routes.defaultMaxBodySize = "32mb"

            // Middleware
            app.middleware.use(JSONErrorMiddleware())

            // Request logging is opt-in: without LOG_FILE the server never writes
            // prompts, responses, or metadata anywhere.
            var inferenceLog: InferenceLog?
            if let path = Environment.get("LOG_FILE"), !path.isEmpty {
                inferenceLog = try InferenceLog(path: path)
                app.logger.info("Logging inference records to \(path)")
            }

            let inferenceService = InferenceService(log: inferenceLog)

            // Background cleanup task — runs every 5 minutes
            let cleanupTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    await inferenceService.cleanupStaleSessions()
                }
            }

            app.post("inference") { req async throws -> InferenceResponse in
                let request = try req.content.decode(InferenceRequest.self)
                return try await inferenceService.generateResponse(
                    for: request.prompt,
                    sessionId: request.sessionId,
                    newSession: request.newSession ?? false,
                    reset: request.reset ?? false,
                    images: request.images ?? [],
                    metadata: request.metadata
                )
            }

            // Closed-set image classification
            app.post("classify") { req async throws -> ClassifyResponse in
                try await inferenceService.classify(req.content.decode(ClassifyRequest.self))
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
            app.get("status") { _ async -> StatusResponse in
                await inferenceService.status()
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
