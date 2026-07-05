import Dependencies
import DependenciesMacros
import Foundation

/// TCA dependency for OpenRouter's chat-completions API. The live value
/// performs real HTTP requests; unit tests script the stream, and
/// integration tests point `live(baseURL:)` at a localhost MockServer.
@DependencyClient
struct OpenRouterClient: Sendable {
  /// Runs one streaming completion; yields text deltas as they arrive.
  /// Throws before returning the stream if the request itself fails
  /// (bad key, network down); mid-stream failures throw out of the stream.
  var streamChat: @Sendable (ChatRequest) async throws -> AsyncThrowingStream<String, Error>
  /// Fetches the available models for the Settings picker, sorted by name.
  /// The key is optional — OpenRouter serves the list unauthenticated too.
  /// Pass a category (e.g. "programming") to get OpenRouter's curated
  /// subset for that use case instead of the full ~340-model catalog.
  var listModels: @Sendable (_ apiKey: String?, _ category: String?) async throws -> [OpenRouterModel]
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
  static let defaultModel = "anthropic/claude-sonnet-4.6"
  static let defaultBaseURL = URL(string: "https://openrouter.ai")!
  /// The category the model picker filters by unless "Show all" is on:
  /// building artifacts is a programming task.
  static let programmingCategory = "programming"

  static let liveValue = OpenRouterClient.live(baseURL: defaultBaseURL)

  static func live(baseURL: URL) -> OpenRouterClient {
    OpenRouterClient(
      streamChat: { request in
        var urlRequest = URLRequest(
          url: baseURL.appendingPathComponent("api/v1/chat/completions")
        )
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
      },
      listModels: { apiKey, category in
        var url = baseURL.appendingPathComponent("api/v1/models")
        if let category,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        {
          components.queryItems = [URLQueryItem(name: "category", value: category)]
          url = components.url ?? url
        }
        var urlRequest = URLRequest(url: url)
        if let apiKey {
          urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
          throw OpenRouterError.invalidResponse
        }
        guard http.statusCode == 200 else {
          throw OpenRouterError.httpStatus(
            http.statusCode,
            body: String(data: data.prefix(2048), encoding: .utf8) ?? ""
          )
        }
        return try JSONDecoder().decode(ModelsResponse.self, from: data).data
          .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      }
    )
  }

  static let testValue = OpenRouterClient()
}

extension DependencyValues {
  var openRouterClient: OpenRouterClient {
    get { self[OpenRouterClient.self] }
    set { self[OpenRouterClient.self] = newValue }
  }
}
