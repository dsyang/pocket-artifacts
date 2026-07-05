import Foundation

/// A named, scripted OpenRouter conversation served by MockServer. The
/// deltas become individual SSE `data:` events, exactly as OpenRouter
/// chunks its streaming completions.
struct Scenario: Sendable {
  /// Text deltas for the streaming completion, in order.
  var deltas: [String]
  /// JSON body served for GET /api/v1/models.
  var modelsJSON: String = Scenario.defaultModelsJSON

  /// The full SSE response body: one `data:` event per delta, then [DONE].
  var sseBody: Data {
    var body = ""
    for delta in deltas {
      let chunk: [String: Any] = ["choices": [["delta": ["content": delta]]]]
      let data = try! JSONSerialization.data(withJSONObject: chunk)
      body += "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }
    body += "data: [DONE]\n\n"
    return Data(body.utf8)
  }
}

extension Scenario {
  static let tipCalculatorHTML = """
    <!DOCTYPE html>
    <html>
    <head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Tip Calculator</title></head>
    <body><h1>Tip Calculator</h1></body>
    </html>
    """

  /// A generation turn: prose, then a fenced HTML file split mid-fence
  /// across deltas (as real streams are), then trailing prose.
  static let happyPath = Scenario(
    deltas: [
      "Here's your tip calculator!\n",
      "```html\n",
      String(tipCalculatorHTML.prefix(80)),
      String(tipCalculatorHTML.dropFirst(80)),
      "\n```\n",
      "Enjoy!",
    ]
  )

  /// A plain chat answer with no HTML fence — no version should be created.
  static let noFence = Scenario(
    deltas: ["I can build small single-page apps. ", "What would you like to make?"]
  )

  static let defaultModelsJSON = """
    {
      "data": [
        {"id": "anthropic/claude-sonnet-4.5", "name": "Anthropic: Claude Sonnet 4.5"},
        {"id": "openai/gpt-5", "name": "OpenAI: GPT-5"},
        {"id": "no-name/model-without-name"}
      ]
    }
    """
}
