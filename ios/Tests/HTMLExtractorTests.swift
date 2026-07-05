import XCTest

@testable import PocketArtifacts

final class HTMLExtractorTests: XCTestCase {
  let html = "<!DOCTYPE html>\n<html><body><h1>Hi</h1></body></html>"

  func testExtractsFenceWithSurroundingProse() {
    let text = "Here's your app!\n```html\n\(html)\n```\nEnjoy!"
    XCTAssertEqual(HTMLExtractor.extract(from: text), html)
  }

  func testExtractsFenceAtStartOfText() {
    let text = "```html\n\(html)\n```"
    XCTAssertEqual(HTMLExtractor.extract(from: text), html)
  }

  func testReturnsNilWhenNoFence() {
    XCTAssertNil(HTMLExtractor.extract(from: "Just a plain answer to your question."))
  }

  func testReturnsNilForUnclosedFence() {
    // A stream cut off mid-file must not produce a version.
    let text = "```html\n<!DOCTYPE html>\n<html><body>"
    XCTAssertNil(HTMLExtractor.extract(from: text))
  }

  func testReturnsNilForNonHTMLFence() {
    let text = "```javascript\nconsole.log(1)\n```"
    XCTAssertNil(HTMLExtractor.extract(from: text))
  }

  func testFirstFenceWinsWhenMultiple() {
    let second = "<html><body>second</body></html>"
    let text = "```html\n\(html)\n```\nand also\n```html\n\(second)\n```"
    XCTAssertEqual(HTMLExtractor.extract(from: text), html)
  }

  func testReturnsNilForEmptyFence() {
    XCTAssertNil(HTMLExtractor.extract(from: "```html\n\n```"))
  }

  // MARK: - title

  func testExtractsTitle() {
    let html = "<html><head><title>Tip Calculator</title></head><body></body></html>"
    XCTAssertEqual(HTMLExtractor.title(from: html), "Tip Calculator")
  }

  func testExtractsTitleCaseInsensitiveWithAttributesAndWhitespace() {
    let html = "<html><head><TITLE lang=\"en\">\n  Timer \n</TITLE></head></html>"
    XCTAssertEqual(HTMLExtractor.title(from: html), "Timer")
  }

  func testTitleNilWhenMissing() {
    XCTAssertNil(HTMLExtractor.title(from: "<html><body><h1>Hi</h1></body></html>"))
  }

  func testTitleNilWhenEmpty() {
    XCTAssertNil(HTMLExtractor.title(from: "<html><head><title>  </title></head></html>"))
  }

  func testTitleNilForUnclosedTag() {
    XCTAssertNil(HTMLExtractor.title(from: "<html><head><title>Oops</head></html>"))
  }

  // MARK: - replacingHTMLFence

  func testReplacesFenceKeepingProse() {
    let text = "Here's your app!\n```html\n\(html)\n```\nEnjoy!"
    let result = HTMLExtractor.replacingHTMLFence(in: text, with: "[omitted]")
    XCTAssertEqual(result, "Here's your app!\n[omitted]\nEnjoy!")
  }

  func testReplaceLeavesTextWithoutFenceUnchanged() {
    let text = "No fence here."
    XCTAssertEqual(HTMLExtractor.replacingHTMLFence(in: text, with: "[omitted]"), text)
  }
}
