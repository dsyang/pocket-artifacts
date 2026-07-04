import ComposableArchitecture
import XCTest

@testable import PocketArtifacts

@MainActor
final class EditorFeatureTests: XCTestCase {
  static let html = "<!DOCTYPE html>\n<html><body><h1>Tip Calculator</h1></body></html>"

  func testHappyPathTurnCreatesVersionAndSwitchesToPreview() async {
    let delta1 = "Here's your app!\n"
    let delta2 = "```html\n\(Self.html)\n```\nEnjoy!"

    let store = TestStore(
      initialState: EditorFeature.State(inputText: "make a tip calculator")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(delta1)
          continuation.yield(delta2)
          continuation.finish()
        }
      }
    }

    await store.send(.sendTapped) {
      $0.inputText = ""
      $0.messages = [
        ChatMessage(id: UUID(0), role: .user, content: "make a tip calculator"),
        ChatMessage(id: UUID(1), role: .assistant, content: ""),
      ]
      $0.streamingMessageID = UUID(1)
      $0.isStreaming = true
    }
    await store.receive(.streamDelta(delta1)) {
      $0.messages[id: UUID(1)]?.content = delta1
    }
    await store.receive(.streamDelta(delta2)) {
      $0.messages[id: UUID(1)]?.content = delta1 + delta2
    }
    await store.receive(.streamFinished) {
      $0.isStreaming = false
      $0.streamingMessageID = nil
      $0.currentHTML = Self.html
      $0.htmlVersion = 1
      $0.tab = .preview
    }
  }

  func testRequestIncludesSystemPromptAndUserMessage() async {
    let sentRequest = LockIsolated<ChatRequest?>(nil)

    let store = TestStore(
      initialState: EditorFeature.State(inputText: "make a timer")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { request in
        sentRequest.setValue(request)
        return AsyncThrowingStream { continuation in
          continuation.finish()
        }
      }
    }

    await store.send(.sendTapped) {
      $0.inputText = ""
      $0.messages = [
        ChatMessage(id: UUID(0), role: .user, content: "make a timer"),
        ChatMessage(id: UUID(1), role: .assistant, content: ""),
      ]
      $0.streamingMessageID = UUID(1)
      $0.isStreaming = true
    }
    await store.receive(.streamFinished) {
      // Nothing arrived, so the empty placeholder bubble is dropped.
      $0.isStreaming = false
      $0.streamingMessageID = nil
      $0.messages = [
        ChatMessage(id: UUID(0), role: .user, content: "make a timer")
      ]
    }

    let request = sentRequest.value
    XCTAssertEqual(request?.apiKey, "sk-or-test")
    XCTAssertEqual(request?.model, OpenRouterClient.defaultModel)
    XCTAssertEqual(
      request?.messages,
      [
        OpenRouterMessage(role: "system", content: ArtifactPrompt.system),
        OpenRouterMessage(role: "user", content: "make a timer"),
      ]
    )
  }

  func testNoFenceResponseIsPlainChatTurn() async {
    let reply = "I can build small single-page apps. What would you like?"

    let store = TestStore(
      initialState: EditorFeature.State(inputText: "what can you do?")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(reply)
          continuation.finish()
        }
      }
    }

    await store.send(.sendTapped) {
      $0.inputText = ""
      $0.messages = [
        ChatMessage(id: UUID(0), role: .user, content: "what can you do?"),
        ChatMessage(id: UUID(1), role: .assistant, content: ""),
      ]
      $0.streamingMessageID = UUID(1)
      $0.isStreaming = true
    }
    await store.receive(.streamDelta(reply)) {
      $0.messages[id: UUID(1)]?.content = reply
    }
    await store.receive(.streamFinished) {
      $0.isStreaming = false
      $0.streamingMessageID = nil
      // No version created, no tab switch.
    }
    XCTAssertNil(store.state.currentHTML)
    XCTAssertEqual(store.state.tab, .chat)
  }

  func testStreamFailureKeepsPartialTextMarkedFailed() async {
    struct StreamError: Error {}

    let store = TestStore(
      initialState: EditorFeature.State(inputText: "make a game")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield("Let me start")
          continuation.finish(throwing: StreamError())
        }
      }
    }

    await store.send(.sendTapped) {
      $0.inputText = ""
      $0.messages = [
        ChatMessage(id: UUID(0), role: .user, content: "make a game"),
        ChatMessage(id: UUID(1), role: .assistant, content: ""),
      ]
      $0.streamingMessageID = UUID(1)
      $0.isStreaming = true
    }
    await store.receive(.streamDelta("Let me start")) {
      $0.messages[id: UUID(1)]?.content = "Let me start"
    }
    await store.receive(.streamFailed(StreamError().localizedDescription)) {
      $0.isStreaming = false
      $0.streamingMessageID = nil
      $0.errorMessage = StreamError().localizedDescription
      $0.messages[id: UUID(1)]?.isFailed = true
    }
    XCTAssertNil(store.state.currentHTML)
  }

  func testCancelKeepsPartialTextAndStopsStream() async {
    let store = TestStore(
      initialState: EditorFeature.State(inputText: "make a game")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield("Working on")
          // Never finishes — the user will cancel.
        }
      }
    }

    await store.send(.sendTapped) {
      $0.inputText = ""
      $0.messages = [
        ChatMessage(id: UUID(0), role: .user, content: "make a game"),
        ChatMessage(id: UUID(1), role: .assistant, content: ""),
      ]
      $0.streamingMessageID = UUID(1)
      $0.isStreaming = true
    }
    await store.receive(.streamDelta("Working on")) {
      $0.messages[id: UUID(1)]?.content = "Working on"
    }
    await store.send(.cancelStreamTapped) {
      $0.isStreaming = false
      $0.streamingMessageID = nil
      $0.messages[id: UUID(1)]?.isFailed = true
    }
  }

  func testMissingAPIKeyEmitsDelegateAndPreservesInput() async {
    let store = TestStore(
      initialState: EditorFeature.State(inputText: "make a timer")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.keychainClient.apiKey = { nil }
    }

    await store.send(.sendTapped)
    await store.receive(.delegate(.apiKeyRequired))
    XCTAssertEqual(store.state.inputText, "make a timer")
    XCTAssertTrue(store.state.messages.isEmpty)
  }

  func testEmptyInputDoesNothing() async {
    let store = TestStore(initialState: EditorFeature.State(inputText: "   ")) {
      EditorFeature()
    }
    await store.send(.sendTapped)
  }
}
