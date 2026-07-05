import Foundation

/// A saved artifact: one single-page HTML app, plus (via foreign keys) its
/// chat transcript and version history.
struct Artifact: Identifiable, Equatable, Sendable, Codable {
  let id: UUID
  var title: String
  var createdAt: Date
  var updatedAt: Date
}

/// One immutable snapshot of an artifact's HTML, created whenever a model
/// response contains a fenced HTML file. Restore never rewrites history —
/// it copies an old version forward as a new, higher-numbered one.
struct ArtifactVersion: Identifiable, Equatable, Sendable, Codable {
  let id: UUID
  var artifactID: UUID
  /// 1-based and monotonically increasing per artifact.
  var number: Int
  var html: String
  var createdAt: Date
}

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

/// One entry from GET /api/v1/models, for the Settings model picker.
struct OpenRouterModel: Identifiable, Equatable, Sendable, Codable {
  var id: String
  var name: String

  init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? self.id
  }
}

/// Decodable envelope of GET /api/v1/models.
struct ModelsResponse: Decodable {
  var data: [OpenRouterModel]
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
