import Dependencies
import DependenciesMacros
import Foundation

/// TCA dependency for OpenRouter's chat-completions API. The live value
/// performs a real streaming HTTP request; tests script the stream.
@DependencyClient
struct OpenRouterClient: Sendable {
  /// Runs one streaming completion; yields text deltas as they arrive.
  /// Throws before returning the stream if the request itself fails
  /// (bad key, network down); mid-stream failures throw out of the stream.
  var streamChat: @Sendable (ChatRequest) async throws -> AsyncThrowingStream<String, Error>
}

enum OpenRouterError: Error, LocalizedError, Equatable {
  case invalidResponse
  case httpStatus(Int, body: String)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "OpenRouter returned an invalid response."
    case .httpStatus(let code, let body):
      let detail = body.isEmpty ? "" : " — \(body.prefix(300))"
      return "OpenRouter request failed (HTTP \(code))\(detail)"
    }
  }
}

extension OpenRouterClient: DependencyKey {
  static let defaultModel = "anthropic/claude-sonnet-4.5"
  static let chatCompletionsURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

  static let liveValue = OpenRouterClient(
    streamChat: { request in
      var urlRequest = URLRequest(url: chatCompletionsURL)
      urlRequest.httpMethod = "POST"
      urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.setValue("https://github.com/dsyang/pocket-artifacts", forHTTPHeaderField: "HTTP-Referer")
      urlRequest.setValue("Pocket Artifacts", forHTTPHeaderField: "X-Title")
      urlRequest.httpBody = try JSONEncoder().encode(
        ChatCompletionRequestBody(model: request.model, messages: request.messages, stream: true)
      )

      let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
      guard let http = response as? HTTPURLResponse else {
        throw OpenRouterError.invalidResponse
      }
      guard http.statusCode == 200 else {
        // Collect a little of the error body so "invalid API key" and
        // friends surface in the UI instead of a bare status code.
        var data = Data()
        for try await byte in bytes {
          data.append(byte)
          if data.count >= 2048 { break }
        }
        throw OpenRouterError.httpStatus(
          http.statusCode,
          body: String(data: data, encoding: .utf8) ?? ""
        )
      }

      return AsyncThrowingStream { continuation in
        let task = Task {
          do {
            for try await line in bytes.lines {
              guard let payload = SSEParser.parse(line: line) else { continue }
              if payload == "[DONE]" { break }
              guard
                let chunk = try? JSONDecoder().decode(
                  ChatCompletionChunk.self, from: Data(payload.utf8)
                ),
                let content = chunk.deltaContent,
                !content.isEmpty
              else { continue }
              continuation.yield(content)
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    }
  )

  static let testValue = OpenRouterClient()
}

extension DependencyValues {
  var openRouterClient: OpenRouterClient {
    get { self[OpenRouterClient.self] }
    set { self[OpenRouterClient.self] = newValue }
  }
}
