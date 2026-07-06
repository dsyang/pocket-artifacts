import ComposableArchitecture
import XCTest

@testable import PocketArtifacts

@MainActor
final class EditorFeatureTests: XCTestCase {
  static let html =
    "<!DOCTYPE html>\n<html><head><title>Tip Calculator</title></head><body><h1>Tips</h1></body></html>"
  static let now = Date(timeIntervalSince1970: 1_234_567_890)
  static let artifact = Artifact(
    id: UUID(100), title: "Untitled", createdAt: now, updatedAt: now
  )

  func testTaskLoadsPersistedTranscriptAndVersions() async {
    let messages = [
      ChatMessage(id: UUID(10), role: .user, content: "make a tip calculator"),
      ChatMessage(id: UUID(11), role: .assistant, content: "```html\n\(Self.html)\n```"),
    ]
    let versions = [
      ArtifactVersion(
        id: UUID(12), artifactID: Self.artifact.id, number: 1, html: Self.html,
        createdAt: Self.now
      )
    ]

    let store = TestStore(initialState: EditorFeature.State(artifact: Self.artifact)) {
      EditorFeature()
    } withDependencies: {
      $0.databaseClient.fetchMessages = { _ in messages }
      $0.databaseClient.fetchVersions = { _ in versions }
    }

    await store.send(.task)
    await store.receive(.loaded(messages: messages, versions: versions)) {
      $0.messages = IdentifiedArray(uniqueElements: messages)
      $0.versions = IdentifiedArray(uniqueElements: versions)
    }
    XCTAssertEqual(store.state.currentHTML, Self.html)
    XCTAssertEqual(store.state.htmlVersion, 1)
  }

  func testHappyPathTurnCreatesVersionDerivesTitleAndSwitchesToPreview() async {
    let delta1 = "Here's your app!\n"
    let delta2 = "```html\n\(Self.html)\n```\nEnjoy!"

    let savedMessages = LockIsolated<[ChatMessage]>([])
    let savedVersions = LockIsolated<[ArtifactVersion]>([])
    let updatedArtifacts = LockIsolated<[Artifact]>([])

    let store = TestStore(
      initialState: EditorFeature.State(
        artifact: Self.artifact, inputText: "make a tip calculator"
      )
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(delta1)
          continuation.yield(delta2)
          continuation.finish()
        }
      }
      $0.databaseClient.saveMessage = { message, _ in
        savedMessages.withValue { $0.append(message) }
      }
      $0.databaseClient.createVersion = { version in
        savedVersions.withValue { $0.append(version) }
      }
      $0.databaseClient.updateArtifact = { artifact in
        updatedArtifacts.withValue { $0.append(artifact) }
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
      $0.artifact.updatedAt = Self.now
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
      $0.versions = [
        ArtifactVersion(
          id: UUID(2), artifactID: Self.artifact.id, number: 1, html: Self.html,
          createdAt: Self.now
        )
      ]
      $0.artifact.title = "Tip Calculator"
      $0.tab = .preview
    }
    XCTAssertEqual(store.state.currentHTML, Self.html)

    // Both the user turn and the finished assistant turn were persisted,
    // along with the version and the retitled artifact.
    XCTAssertEqual(savedMessages.value.map(\.role), [.user, .assistant])
    XCTAssertEqual(savedVersions.value.map(\.number), [1])
    XCTAssertEqual(savedVersions.value.first?.html, Self.html)
    XCTAssertEqual(updatedArtifacts.value.last?.title, "Tip Calculator")
  }

  func testSecondTurnIncrementsVersionNumber() async {
    let existing = ArtifactVersion(
      id: UUID(50), artifactID: Self.artifact.id, number: 3, html: "<p>old</p>",
      createdAt: Self.now
    )
    let reply = "```html\n\(Self.html)\n```"

    let store = TestStore(
      initialState: EditorFeature.State(
        artifact: Self.artifact,
        versions: [existing],
        inputText: "make the buttons bigger"
      )
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(reply)
          continuation.finish()
        }
      }
      $0.databaseClient.saveMessage = { _, _ in }
      $0.databaseClient.createVersion = { _ in }
      $0.databaseClient.updateArtifact = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.sendTapped)
    await store.receive(\.streamFinished)
    XCTAssertEqual(store.state.versions.last?.number, 4)
    XCTAssertEqual(store.state.currentHTML, Self.html)
  }

  func testRequestIncludesSystemPromptAndUserMessage() async {
    let sentRequest = LockIsolated<ChatRequest?>(nil)

    let store = TestStore(
      initialState: EditorFeature.State(artifact: Self.artifact, inputText: "make a timer")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { request in
        sentRequest.setValue(request)
        return AsyncThrowingStream { continuation in
          continuation.finish()
        }
      }
      $0.databaseClient.saveMessage = { _, _ in }
      $0.databaseClient.updateArtifact = { _ in }
    }

    await store.send(.sendTapped) {
      $0.inputText = ""
      $0.messages = [
        ChatMessage(id: UUID(0), role: .user, content: "make a timer"),
        ChatMessage(id: UUID(1), role: .assistant, content: ""),
      ]
      $0.streamingMessageID = UUID(1)
      $0.isStreaming = true
      $0.artifact.updatedAt = Self.now
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

  func testArtifactModelIsUsedForRequests() async {
    let sentRequest = LockIsolated<ChatRequest?>(nil)

    // Model choice is per-chat: it rides on the artifact, not a global pref.
    var artifact = Self.artifact
    artifact.model = "openai/gpt-5"

    let store = TestStore(
      initialState: EditorFeature.State(artifact: artifact, inputText: "make a timer")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { request in
        sentRequest.setValue(request)
        return AsyncThrowingStream { continuation in
          continuation.finish()
        }
      }
      $0.databaseClient.saveMessage = { _, _ in }
      $0.databaseClient.updateArtifact = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.sendTapped)
    await store.receive(\.streamFinished)
    XCTAssertEqual(sentRequest.value?.model, "openai/gpt-5")
  }

  func testPickingModelStoresItOnTheArtifactAndPersists() async {
    let updated = LockIsolated<[Artifact]>([])

    let store = TestStore(
      initialState: EditorFeature.State(artifact: Self.artifact)
    ) {
      EditorFeature()
    } withDependencies: {
      $0.databaseClient.updateArtifact = { artifact in
        updated.withValue { $0.append(artifact) }
      }
    }

    await store.send(.modelButtonTapped) {
      $0.modelPicker = ModelPickerFeature.State(
        selectedModel: OpenRouterClient.defaultModel
      )
    }
    await store.send(.modelPicker(.presented(.modelSelected("openai/gpt-5")))) {
      $0.modelPicker?.selectedModel = "openai/gpt-5"
    }
    await store.receive(.modelPicker(.presented(.delegate(.modelSelected("openai/gpt-5"))))) {
      $0.artifact.model = "openai/gpt-5"
    }
    XCTAssertEqual(updated.value.last?.model, "openai/gpt-5")
  }

  func testNoFenceResponseIsPlainChatTurn() async {
    let reply = "I can build small single-page apps. What would you like?"
    let savedMessages = LockIsolated<[ChatMessage]>([])

    let store = TestStore(
      initialState: EditorFeature.State(artifact: Self.artifact, inputText: "what can you do?")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(reply)
          continuation.finish()
        }
      }
      $0.databaseClient.saveMessage = { message, _ in
        savedMessages.withValue { $0.append(message) }
      }
      $0.databaseClient.updateArtifact = { _ in }
    }

    await store.send(.sendTapped) {
      $0.inputText = ""
      $0.messages = [
        ChatMessage(id: UUID(0), role: .user, content: "what can you do?"),
        ChatMessage(id: UUID(1), role: .assistant, content: ""),
      ]
      $0.streamingMessageID = UUID(1)
      $0.isStreaming = true
      $0.artifact.updatedAt = Self.now
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
    // The assistant reply is still persisted as part of the transcript.
    XCTAssertEqual(savedMessages.value.map(\.content), ["what can you do?", reply])
  }

  func testStreamFailureKeepsPartialTextMarkedFailedAndPersistsIt() async {
    struct StreamError: Error {}
    let savedMessages = LockIsolated<[ChatMessage]>([])

    let store = TestStore(
      initialState: EditorFeature.State(artifact: Self.artifact, inputText: "make a game")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield("Let me start")
          continuation.finish(throwing: StreamError())
        }
      }
      $0.databaseClient.saveMessage = { message, _ in
        savedMessages.withValue { $0.append(message) }
      }
      $0.databaseClient.updateArtifact = { _ in }
    }

    await store.send(.sendTapped) {
      $0.inputText = ""
      $0.messages = [
        ChatMessage(id: UUID(0), role: .user, content: "make a game"),
        ChatMessage(id: UUID(1), role: .assistant, content: ""),
      ]
      $0.streamingMessageID = UUID(1)
      $0.isStreaming = true
      $0.artifact.updatedAt = Self.now
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
    XCTAssertEqual(savedMessages.value.last?.isFailed, true)
  }

  func testCancelKeepsPartialTextAndStopsStream() async {
    let store = TestStore(
      initialState: EditorFeature.State(artifact: Self.artifact, inputText: "make a game")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.streamChat = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield("Working on")
          // Never finishes — the user will cancel.
        }
      }
      $0.databaseClient.saveMessage = { _, _ in }
      $0.databaseClient.updateArtifact = { _ in }
    }

    await store.send(.sendTapped) {
      $0.inputText = ""
      $0.messages = [
        ChatMessage(id: UUID(0), role: .user, content: "make a game"),
        ChatMessage(id: UUID(1), role: .assistant, content: ""),
      ]
      $0.streamingMessageID = UUID(1)
      $0.isStreaming = true
      $0.artifact.updatedAt = Self.now
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

  func testRestoreCopiesOldVersionForward() async {
    let v1 = ArtifactVersion(
      id: UUID(10), artifactID: Self.artifact.id, number: 1, html: "<p>one</p>",
      createdAt: Self.now
    )
    let v2 = ArtifactVersion(
      id: UUID(11), artifactID: Self.artifact.id, number: 2, html: "<p>two</p>",
      createdAt: Self.now
    )
    let savedVersions = LockIsolated<[ArtifactVersion]>([])

    let store = TestStore(
      initialState: EditorFeature.State(artifact: Self.artifact, versions: [v1, v2])
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
      $0.databaseClient.createVersion = { version in
        savedVersions.withValue { $0.append(version) }
      }
      $0.databaseClient.updateArtifact = { _ in }
    }

    await store.send(.historyButtonTapped) {
      $0.versionHistory = VersionHistoryFeature.State(versions: [v2, v1])
    }
    await store.send(.versionHistory(.presented(.restoreTapped(v1))))
    await store.receive(.versionHistory(.presented(.delegate(.restore(v1))))) {
      $0.versionHistory = nil
      $0.versions = [
        v1, v2,
        ArtifactVersion(
          id: UUID(0), artifactID: Self.artifact.id, number: 3, html: v1.html,
          createdAt: Self.now
        ),
      ]
      $0.tab = .preview
    }
    // History is never rewritten — the restore is a new, higher version.
    XCTAssertEqual(savedVersions.value.map(\.number), [3])
    XCTAssertEqual(savedVersions.value.first?.html, v1.html)
    XCTAssertEqual(store.state.htmlVersion, 3)
  }

  func testMissingAPIKeyEmitsDelegateAndPreservesInput() async {
    let store = TestStore(
      initialState: EditorFeature.State(artifact: Self.artifact, inputText: "make a timer")
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
    let store = TestStore(
      initialState: EditorFeature.State(artifact: Self.artifact, inputText: "   ")
    ) {
      EditorFeature()
    }
    await store.send(.sendTapped)
  }
}
