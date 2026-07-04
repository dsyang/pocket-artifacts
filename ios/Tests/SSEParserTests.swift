import XCTest

@testable import PocketArtifacts

final class SSEParserTests: XCTestCase {
  // MARK: - parse(line:)

  func testParsesDataLine() {
    XCTAssertEqual(SSEParser.parse(line: "data: {\"a\":1}"), "{\"a\":1}")
  }

  func testParsesDataLineWithoutSpace() {
    XCTAssertEqual(SSEParser.parse(line: "data:{\"a\":1}"), "{\"a\":1}")
  }

  func testParsesDoneSentinel() {
    XCTAssertEqual(SSEParser.parse(line: "data: [DONE]"), "[DONE]")
  }

  func testStripsTrailingCarriageReturn() {
    XCTAssertEqual(SSEParser.parse(line: "data: hello\r"), "hello")
  }

  func testIgnoresCommentLines() {
    XCTAssertNil(SSEParser.parse(line: ": OPENROUTER PROCESSING"))
  }

  func testIgnoresBlankLines() {
    XCTAssertNil(SSEParser.parse(line: ""))
  }

  func testIgnoresOtherSSEFields() {
    XCTAssertNil(SSEParser.parse(line: "event: message"))
    XCTAssertNil(SSEParser.parse(line: "id: 42"))
  }

  // MARK: - feed(_:) chunk reassembly

  func testFeedReassemblesLineSplitAcrossChunks() {
    var parser = SSEParser()
    XCTAssertEqual(parser.feed("da"), [])
    XCTAssertEqual(parser.feed("ta: {\"delta\":\"hi\"}"), [])
    XCTAssertEqual(parser.feed("\n"), ["{\"delta\":\"hi\"}"])
  }

  func testFeedHandlesMultipleEventsInOneChunk() {
    var parser = SSEParser()
    let payloads = parser.feed("data: one\n\ndata: two\n\ndata: [DONE]\n")
    XCTAssertEqual(payloads, ["one", "two", "[DONE]"])
  }

  func testFeedHandlesCRLFLineEndings() {
    var parser = SSEParser()
    let payloads = parser.feed("data: one\r\ndata: two\r\n")
    XCTAssertEqual(payloads, ["one", "two"])
  }

  func testFeedBuffersPartialTrailingLine() {
    var parser = SSEParser()
    XCTAssertEqual(parser.feed("data: complete\ndata: parti"), ["complete"])
    XCTAssertEqual(parser.feed("al\n"), ["partial"])
  }

  func testFeedIgnoresCommentsAndBlanksBetweenEvents() {
    var parser = SSEParser()
    let payloads = parser.feed(": OPENROUTER PROCESSING\n\ndata: real\n\n")
    XCTAssertEqual(payloads, ["real"])
  }
}
