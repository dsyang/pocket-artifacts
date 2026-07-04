import Foundation

/// Incremental parser for Server-Sent Events as used by OpenRouter's
/// streaming chat completions: extracts the payload of `data:` lines,
/// ignoring comment lines (": OPENROUTER PROCESSING") and blank separators.
///
/// Two entry points:
/// - `parse(line:)` for input already split into lines (e.g. `URLSession.AsyncBytes.lines`)
/// - `feed(_:)` for raw chunks with arbitrary boundaries, including `data:`
///   lines split across chunks; partial trailing lines are buffered.
struct SSEParser {
  private var buffer = ""

  init() {}

  /// Parses a single line (without trailing newline). Returns the `data:`
  /// payload, or nil for comments, blank lines, and other SSE fields.
  static func parse(line: String) -> String? {
    var line = line
    if line.hasSuffix("\r") {
      line.removeLast()
    }
    guard line.hasPrefix("data:") else { return nil }
    var payload = line.dropFirst("data:".count)
    if payload.hasPrefix(" ") {
      payload = payload.dropFirst()
    }
    return String(payload)
  }

  /// Feeds a raw chunk of the response body; returns the payloads of all
  /// `data:` lines completed by this chunk.
  ///
  /// Note: "\r\n" is a single Character in Swift, so a plain search for
  /// "\n" would never match CRLF-terminated lines.
  mutating func feed(_ chunk: String) -> [String] {
    buffer += chunk
    var payloads: [String] = []
    while let newlineIndex = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
      let line = String(buffer[buffer.startIndex..<newlineIndex])
      buffer = String(buffer[buffer.index(after: newlineIndex)...])
      if let payload = Self.parse(line: line) {
        payloads.append(payload)
      }
    }
    return payloads
  }
}
