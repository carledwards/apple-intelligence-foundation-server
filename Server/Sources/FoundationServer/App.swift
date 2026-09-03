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
                    instructions: request.instructions,
                    metadata: request.metadata
                )
            }

            // Same prompt, N times, grouped by answer. For probing what the
            // model actually says, where /classify constrains it to a vocabulary.
            app.post("sample") { req async throws -> SampleRun in
                let request = try req.content.decode(SampleRequest.self)
                return try await inferenceService.sample(
                    prompt: request.prompt,
                    images: request.images ?? [],
                    instructions: request.instructions,
                    samples: request.samples ?? 3,
                    choices: request.choices,
                    metadata: request.metadata
                )
            }

            // Closed-set image classification
            app.post("classify") { req async throws -> ClassifyResponse in
                try await inferenceService.classify(req.content.decode(ClassifyRequest.self))
            }

            // Session management
            app.post("sessions") { req async -> CreateSessionResponse in
                // The body is optional: `POST /sessions` with nothing at all is
                // still the way to get a plain session.
                let instructions = (try? req.content.decode(CreateSessionRequest.self))?.instructions
                let id = await inferenceService.createSession(instructions: instructions)
                return CreateSessionResponse(
                    sessionId: id,
                    instructions: await inferenceService.instructions(for: id)
                )
            }

            app.delete("sessions", ":sessionId") { req async throws -> DeleteSessionResponse in
                guard let sessionId = req.parameters.get("sessionId") else {
                    throw Abort(.badRequest, reason: "Missing session ID")
                }
                await inferenceService.deleteSession(sessionId)
                return DeleteSessionResponse(message: "Session deleted")
            }

            // How much of a session's context budget is spent. Polled by a UI
            // that wants to show the ceiling approaching rather than only
            // reporting the crash into it.
            app.get("sessions", ":sessionId", "context") { req async throws -> ContextUsage in
                guard let sessionId = req.parameters.get("sessionId") else {
                    throw Abort(.badRequest, reason: "Missing session ID")
                }
                return try await inferenceService.contextUsage(sessionId: sessionId)
            }

            // What a prompt would cost before sending it.
            app.post("tokens") { req async throws -> TokenCountResponse in
                let request = try req.content.decode(TokenCountRequest.self)
                let tokens = try await inferenceService.tokenCount(
                    for: request.prompt, images: request.images ?? []
                )
                return TokenCountResponse(
                    tokens: tokens,
                    contextSize: await inferenceService.status().contextSize
                )
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
