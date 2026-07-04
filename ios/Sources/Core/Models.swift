import Foundation

/// A single turn in the artifact-building conversation.
struct ChatMessage: Identifiable, Equatable, Sendable, Codable {
  enum Role: String, Equatable, Sendable, Codable {
    case user
    case assistant
  }

  let id: UUID
  var role: Role
  var content: String
  /// Set when a stream failed or was cancelled mid-turn; failed messages are
  /// kept visible in the transcript but excluded from future model context.
  var isFailed: Bool = false
}

/// A role/content pair in OpenRouter's chat-completions wire format.
struct OpenRouterMessage: Equatable, Sendable, Codable {
  var role: String
  var content: String
}

/// Everything the OpenRouter client needs to run one streaming completion.
struct ChatRequest: Equatable, Sendable {
  var model: String
  var messages: [OpenRouterMessage]
  var apiKey: String
}

/// Encodable body for POST /api/v1/chat/completions.
struct ChatCompletionRequestBody: Encodable {
  var model: String
  var messages: [OpenRouterMessage]
  var stream: Bool
}

/// Decodable shape of one SSE `data:` payload from a streaming completion.
/// Fields we don't use are omitted; OpenRouter also sends chunks with empty
/// or missing `choices` (e.g. the final usage chunk), hence the optionals.
struct ChatCompletionChunk: Decodable {
  struct Choice: Decodable {
    struct Delta: Decodable {
      var content: String?
    }

    var delta: Delta?
  }

  var choices: [Choice]?

  /// The text content of this chunk, if any.
  var deltaContent: String? {
    choices?.first?.delta?.content
  }
}
