# Apple Intelligence Foundation Server (macOS)

A Swift command-line HTTP server that exposes the Apple Intelligence system language model over a simple JSON REST API using Apple's `FoundationModels` framework. Run it locally on supported devices to perform on-device language model inference.

This package is intended for experimentation and local development with Apple Intelligence.

---

## Requirements

- **macOS 26.0+** (or iOS 26.0+, iPadOS 26.0+, visionOS 26.0+)
- **Swift 6.2+**
- **Apple Intelligence enabled** on your device
- **Xcode 17+** (for building)

> Only devices that support Apple Intelligence can use this server. You must enable Apple Intelligence in System Settings.

---

## Project Structure

```text
apple-intelligence-foundation-server/
├── Package.swift              # Swift Package Manager configuration
├── Sources/
│   └── App/
│       └── main.swift         # Server implementation
└── README.md
```

---

## Installation

1. Clone or navigate to the project directory
2. Resolve dependencies:
   ```bash
   swift package resolve
   ```

---

## Usage

### Running the server

```bash
swift run
```

The server will start on:

```text
http://localhost:8080
```

---

## API Overview

All responses are JSON. Errors are also returned as JSON with a consistent shape:

```json
{
  "error": "Human-readable error message"
}
```

### Endpoint summary

| Method | Path         | Description                                  |
|--------|--------------|----------------------------------------------|
| POST   | `/inference` | Run text generation via Apple Intelligence   |
| GET    | `/health`    | Basic liveness/health check                  |

---

## API Endpoints

### POST `/inference`

Send a prompt and receive a generated response from Apple Intelligence.

**Request:**

```bash
curl -X POST http://localhost:8080/inference \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is Swift programming?"}'
```

**Request body:**

```json
{
  "prompt": "Your prompt text here"
}
```

**Successful response:**

```json
{
  "response": "Generated text from Apple Intelligence..."
}
```

If the model is not available, you will receive an error response describing the issue.

---

### GET `/health`

Health check endpoint to verify the server is running.

**Request:**

```bash
curl http://localhost:8080/health
```

**Response:**

```json
{
  "status": "ok"
}
```

---

## Implementation Details

- **Web framework**: [Vapor](https://github.com/vapor/vapor) 4.89.0
- **AI integration**: `FoundationModels` framework (Apple's on-device language model)
- **Architecture**: Async/await with Actor-based inference service for concurrency safety
- **Port**: 8080 (default Vapor HTTP port)
- **Context window**: Up to 4,096 tokens per session (approximately 12,000-16,000 characters for English)

### Model capabilities

The Apple Intelligence system language model excels at:
- Text generation
- Summarization
- Entity extraction
- Creative writing
- Classification

**Not suitable for**: Basic math, code generation, complex logical reasoning

---

## Best Practices

### Performance tips

- Keep prompts focused and specific
- Limit prompt length for faster responses
- Use phrases like "in three sentences" to get concise responses
- Create a new session for each independent request
- Stay within the 4,096 token context limit

---

## Troubleshooting

### Model not available

If you get `"Model is unavailable"` errors:

1. **Device not eligible**  
   Your device may not support Apple Intelligence. Check [Apple's compatibility list](https://www.apple.com/apple-intelligence/).

2. **Apple Intelligence not enabled**  
   Go to **System Settings → Apple Intelligence** and enable it.

3. **Model not ready**  
   The model may still be downloading. Wait a few minutes and try again.

### Build errors

If you encounter module import errors:

1. Ensure you're running **macOS 26.0+** or equivalent platform version
2. Verify you're using **Xcode 17+**
3. Re-resolve dependencies:
   ```bash
   swift package resolve
   ```
4. If necessary, clean and rebuild:
   ```bash
   swift package clean
   swift build
   ```

---

## References

- [FoundationModels Framework Documentation](https://developer.apple.com/documentation/FoundationModels)
- [Generating content and performing tasks with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Apple Intelligence](https://www.apple.com/apple-intelligence/)

---

## License

This project is licensed under the **MIT License**.  
See the [`LICENSE`](./LICENSE) file for details.
