import Foundation

/// Builds the message array sent to OpenRouter for a turn.
///
/// To keep token cost linear across refinements instead of quadratic, older
/// assistant responses have their HTML fences replaced with a short
/// placeholder — only the latest HTML-bearing response is sent in full.
/// Failed (errored/cancelled) messages are excluded entirely.
enum ChatContext {
  static let omittedVersionPlaceholder =
    "[An earlier version of the HTML file was here; it has been omitted to save space. The latest version appears in full in a later message.]"

  static func build(messages: [ChatMessage]) -> [OpenRouterMessage] {
    let active = messages.filter { !$0.isFailed }
    let lastHTMLMessageID = active.last { message in
      message.role == .assistant && HTMLExtractor.extract(from: message.content) != nil
    }?.id

    var result = [OpenRouterMessage(role: "system", content: ArtifactPrompt.system)]
    for message in active {
      var content = message.content
      if message.role == .assistant,
        message.id != lastHTMLMessageID,
        HTMLExtractor.extract(from: content) != nil
      {
        content = HTMLExtractor.replacingHTMLFence(in: content, with: omittedVersionPlaceholder)
      }
      result.append(OpenRouterMessage(role: message.role.rawValue, content: content))
    }
    return result
  }
}
