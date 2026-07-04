import XCTest

@testable import PocketArtifacts

final class ChatContextTests: XCTestCase {
  private func htmlReply(_ body: String) -> String {
    "Sure!\n```html\n<html><body>\(body)</body></html>\n```\nDone."
  }

  func testStartsWithSystemPrompt() {
    let context = ChatContext.build(messages: [])
    XCTAssertEqual(context.count, 1)
    XCTAssertEqual(context[0].role, "system")
    XCTAssertEqual(context[0].content, ArtifactPrompt.system)
  }

  func testOlderHTMLRepliesAreCollapsedLatestKeptInFull() {
    let messages: [ChatMessage] = [
      ChatMessage(id: UUID(), role: .user, content: "make a timer"),
      ChatMessage(id: UUID(), role: .assistant, content: htmlReply("v1")),
      ChatMessage(id: UUID(), role: .user, content: "make it pink"),
      ChatMessage(id: UUID(), role: .assistant, content: htmlReply("v2")),
    ]
    let context = ChatContext.build(messages: messages)

    XCTAssertEqual(context.count, 5)
    XCTAssertEqual(
      context[2].content,
      "Sure!\n\(ChatContext.omittedVersionPlaceholder)\nDone."
    )
    XCTAssertEqual(context[4].content, htmlReply("v2"))
  }

  func testPlainAssistantChatTurnsAreLeftAlone() {
    let messages: [ChatMessage] = [
      ChatMessage(id: UUID(), role: .user, content: "what can you do?"),
      ChatMessage(id: UUID(), role: .assistant, content: "I build small HTML apps."),
    ]
    let context = ChatContext.build(messages: messages)
    XCTAssertEqual(context[2].content, "I build small HTML apps.")
  }

  func testFailedMessagesAreExcluded() {
    let messages: [ChatMessage] = [
      ChatMessage(id: UUID(), role: .user, content: "make a timer"),
      ChatMessage(id: UUID(), role: .assistant, content: "partial garbage", isFailed: true),
      ChatMessage(id: UUID(), role: .user, content: "try again"),
    ]
    let context = ChatContext.build(messages: messages)
    XCTAssertEqual(context.count, 3)
    XCTAssertEqual(context[1].content, "make a timer")
    XCTAssertEqual(context[2].content, "try again")
  }

  func testSingleHTMLReplyIsKeptInFull() {
    let messages: [ChatMessage] = [
      ChatMessage(id: UUID(), role: .user, content: "make a timer"),
      ChatMessage(id: UUID(), role: .assistant, content: htmlReply("v1")),
    ]
    let context = ChatContext.build(messages: messages)
    XCTAssertEqual(context[2].content, htmlReply("v1"))
  }
}
