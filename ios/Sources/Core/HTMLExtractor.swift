import Foundation

/// Pulls the ```html fenced code block out of a model response. The system
/// prompt requires at most one fence per response; if the model emits more
/// than one anyway, the first wins.
enum HTMLExtractor {
  /// The range of the full fence (from the opening ```html through the
  /// closing ```), and the range of the HTML content inside it.
  private static func fenceRanges(
    in text: String
  ) -> (fence: Range<String.Index>, content: Range<String.Index>)? {
    guard let open = text.range(of: "```html") else { return nil }
    guard let newline = text[open.upperBound...].firstIndex(of: "\n") else { return nil }
    let contentStart = text.index(after: newline)
    guard let close = text.range(of: "\n```", range: contentStart..<text.endIndex) else {
      return nil
    }
    return (fence: open.lowerBound..<close.upperBound, content: contentStart..<close.lowerBound)
  }

  /// Returns the HTML inside the first ```html fenced block, or nil if the
  /// response has no complete fence (a plain chat answer, or a stream that
  /// was cut off before the closing fence).
  static func extract(from text: String) -> String? {
    guard let ranges = fenceRanges(in: text) else { return nil }
    let html = String(text[ranges.content])
    return html.isEmpty ? nil : html
  }

  /// Replaces the entire first ```html fenced block with a placeholder,
  /// keeping surrounding prose. Used to shrink older assistant turns when
  /// building model context. Returns the text unchanged if there is no fence.
  static func replacingHTMLFence(in text: String, with placeholder: String) -> String {
    guard let ranges = fenceRanges(in: text) else { return text }
    var result = text
    result.replaceSubrange(ranges.fence, with: placeholder)
    return result
  }
}
