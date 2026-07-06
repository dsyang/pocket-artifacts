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

  // MARK: - Load + observe

  func testTaskLoadsPersistedTranscriptAndVersionsThenObservesFeed() async {
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
      $0.generationClient.events = { _ in
        AsyncStream { continuation in
          continuation.yield(.snapshot(nil))
          continuation.finish()
        }
      }
    }

    await store.send(.task)
    await store.receive(.loaded(messages: messages, versions: versions)) {
      $0.messages = IdentifiedArray(uniqueElements: messages)
      $0.versions = IdentifiedArray(uniqueElements: versions)
    }
    // An idle snapshot leaves streaming state untouched.
    await store.receive(.generation(.snapshot(nil)))
    XCTAssertEqual(store.state.currentHTML, Self.html)
    XCTAssertEqual(store.state.htmlVersion, 1)
  }

  // MARK: - Sending

  func testSendTappedBuildsTurnAndStartsGeneration() async {
    let recordedTurn = LockIsolated<GenerationTurn?>(nil)

    let store = TestStore(
      initialState: EditorFeature.State(artifact: Self.artifact, inputText: "make a timer")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.generationClient.start = { turn in
        recordedTurn.setValue(turn)
        return true
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
      $0.artifact.updatedAt = Self.now
    }
    await store.finish()

    let turn = recordedTurn.value
    XCTAssertEqual(turn?.assistantMessageID, UUID(1))
    XCTAssertEqual(turn?.userMessage, ChatMessage(id: UUID(0), role: .user, content: "make a timer"))
    XCTAssertEqual(turn?.request.apiKey, "sk-or-test")
    XCTAssertEqual(turn?.request.model, OpenRouterClient.defaultModel)
    XCTAssertEqual(
      turn?.request.messages,
      [
        OpenRouterMessage(role: "system", content: ArtifactPrompt.system),
        OpenRouterMessage(role: "user", content: "make a timer"),
      ]
    )
  }

  func testSendTappedUsesArtifactModel() async {
    let recordedTurn = LockIsolated<GenerationTurn?>(nil)

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
      $0.generationClient.start = { turn in
        recordedTurn.setValue(turn)
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.sendTapped)
    await store.finish()
    XCTAssertEqual(recordedTurn.value?.request.model, "openai/gpt-5")
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

  func testStartRejectedRollsBackOptimisticBubbles() async {
    let store = TestStore(
      initialState: EditorFeature.State(artifact: Self.artifact, inputText: "make a timer")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
      $0.keychainClient.apiKey = { "sk-or-test" }
      // The artifact already has an in-flight turn (a re-entry race).
      $0.generationClient.start = { _ in false }
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
    await store.receive(
      .startRejected(userMessageID: UUID(0), assistantMessageID: UUID(1), prompt: "make a timer")
    ) {
      $0.isStreaming = false
      $0.streamingMessageID = nil
      $0.messages = []
      $0.inputText = "make a timer"
    }
  }

  // MARK: - Observing generation events

  func testDeltaAppendsToStreamingBubble() async {
    let store = TestStore(
      initialState: EditorFeature.State(
        artifact: Self.artifact,
        messages: [
          ChatMessage(id: UUID(0), role: .user, content: "hi"),
          ChatMessage(id: UUID(1), role: .assistant, content: "Hello "),
        ],
        isStreaming: true,
        streamingMessageID: UUID(1)
      )
    ) {
      EditorFeature()
    }

    await store.send(.generation(.delta(messageID: UUID(1), text: "world"))) {
      $0.messages[id: UUID(1)]?.content = "Hello world"
    }
  }

  func testCompletedWithVersionAppliesTitleAndSwitchesToPreview() async {
    let finalMessage = ChatMessage(
      id: UUID(1), role: .assistant, content: "```html\n\(Self.html)\n```"
    )
    let version = ArtifactVersion(
      id: UUID(2), artifactID: Self.artifact.id, number: 1, html: Self.html, createdAt: Self.now
    )
    var updatedArtifact = Self.artifact
    updatedArtifact.title = "Tip Calculator"
    updatedArtifact.updatedAt = Self.now
    let result = GenerationResult(
      messageID: UUID(1), message: finalMessage, version: version, artifact: updatedArtifact
    )

    let store = TestStore(
      initialState: EditorFeature.State(
        artifact: Self.artifact,
        messages: [
          ChatMessage(id: UUID(0), role: .user, content: "make a tip calculator"),
          ChatMessage(id: UUID(1), role: .assistant, content: "partial"),
        ],
        isStreaming: true,
        streamingMessageID: UUID(1)
      )
    ) {
      EditorFeature()
    }

    await store.send(.generation(.completed(result))) {
      $0.isStreaming = false
      $0.streamingMessageID = nil
      $0.messages[id: UUID(1)] = finalMessage
      $0.versions = [version]
      $0.tab = .preview
      $0.artifact = updatedArtifact
    }
    XCTAssertEqual(store.state.currentHTML, Self.html)
  }

  func testCompletedNoFenceStaysOnChat() async {
    let reply = ChatMessage(id: UUID(1), role: .assistant, content: "I can build small apps.")
    let result = GenerationResult(messageID: UUID(1), message: reply)

    let store = TestStore(
      initialState: EditorFeature.State(
        artifact: Self.artifact,
        messages: [
          ChatMessage(id: UUID(0), role: .user, content: "what can you do?"),
          ChatMessage(id: UUID(1), role: .assistant, content: "I can build small apps."),
        ],
        isStreaming: true,
        streamingMessageID: UUID(1)
      )
    ) {
      EditorFeature()
    }

    await store.send(.generation(.completed(result))) {
      $0.isStreaming = false
      $0.streamingMessageID = nil
      $0.messages[id: UUID(1)] = reply
    }
    XCTAssertEqual(store.state.tab, .chat)
    XCTAssertNil(store.state.currentHTML)
  }

  func testCompletedFailureShowsErrorAndMarksBubble() async {
    let failed = ChatMessage(id: UUID(1), role: .assistant, content: "Let me start", isFailed: true)
    let result = GenerationResult(messageID: UUID(1), message: failed, errorMessage: "network down")

    let store = TestStore(
      initialState: EditorFeature.State(
        artifact: Self.artifact,
        messages: [
          ChatMessage(id: UUID(0), role: .user, content: "make a game"),
          ChatMessage(id: UUID(1), role: .assistant, content: "Let me start"),
        ],
        isStreaming: true,
        streamingMessageID: UUID(1)
      )
    ) {
      EditorFeature()
    }

    await store.send(.generation(.completed(result))) {
      $0.isStreaming = false
      $0.streamingMessageID = nil
      $0.messages[id: UUID(1)] = failed
      $0.errorMessage = "network down"
    }
  }

  func testCompletedCancelledMarksBubbleFailed() async {
    let failed = ChatMessage(id: UUID(1), role: .assistant, content: "Working on", isFailed: true)
    let result = GenerationResult(messageID: UUID(1), message: failed, wasCancelled: true)

    let store = TestStore(
      initialState: EditorFeature.State(
        artifact: Self.artifact,
        messages: [
          ChatMessage(id: UUID(0), role: .user, content: "make a game"),
          ChatMessage(id: UUID(1), role: .assistant, content: "Working on"),
        ],
        isStreaming: true,
        streamingMessageID: UUID(1)
      )
    ) {
      EditorFeature()
    }

    await store.send(.generation(.completed(result))) {
      $0.isStreaming = false
      $0.streamingMessageID = nil
      $0.messages[id: UUID(1)] = failed
    }
  }

  func testCompletedEmptyResponseDropsBubble() async {
    let result = GenerationResult(messageID: UUID(1), message: nil)

    let store = TestStore(
      initialState: EditorFeature.State(
        artifact: Self.artifact,
        messages: [
          ChatMessage(id: UUID(0), role: .user, content: "make a timer"),
          ChatMessage(id: UUID(1), role: .assistant, content: ""),
        ],
        isStreaming: true,
        streamingMessageID: UUID(1)
      )
    ) {
      EditorFeature()
    }

    await store.send(.generation(.completed(result))) {
      $0.isStreaming = false
      $0.streamingMessageID = nil
      $0.messages.remove(id: UUID(1))
    }
  }

  // MARK: - Re-attach

  func testSnapshotReattachesToInFlightTurn() async {
    let store = TestStore(
      initialState: EditorFeature.State(
        artifact: Self.artifact,
        messages: [ChatMessage(id: UUID(0), role: .user, content: "make a game")]
      )
    ) {
      EditorFeature()
    }

    await store.send(
      .generation(.snapshot(GenerationSnapshot(messageID: UUID(1), partialContent: "Half done")))
    ) {
      $0.isStreaming = true
      $0.streamingMessageID = UUID(1)
      $0.messages.append(ChatMessage(id: UUID(1), role: .assistant, content: "Half done"))
    }
  }

  func testSnapshotReconcilesCheckpointRow() async {
    let store = TestStore(
      initialState: EditorFeature.State(
        artifact: Self.artifact,
        messages: [
          ChatMessage(id: UUID(0), role: .user, content: "make a game"),
          // A checkpoint written while the app was backgrounded, loaded from
          // the DB and marked failed.
          ChatMessage(id: UUID(1), role: .assistant, content: "old partial", isFailed: true),
        ]
      )
    ) {
      EditorFeature()
    }

    await store.send(
      .generation(.snapshot(GenerationSnapshot(messageID: UUID(1), partialContent: "new longer partial")))
    ) {
      $0.isStreaming = true
      $0.streamingMessageID = UUID(1)
      $0.messages[id: UUID(1)]?.content = "new longer partial"
      $0.messages[id: UUID(1)]?.isFailed = false
    }
  }

  // MARK: - Cancel

  func testCancelStreamTappedCallsService() async {
    let recordedCancel = LockIsolated<UUID?>(nil)

    let store = TestStore(
      initialState: EditorFeature.State(
        artifact: Self.artifact,
        messages: [
          ChatMessage(id: UUID(0), role: .user, content: "make a game"),
          ChatMessage(id: UUID(1), role: .assistant, content: "Working on"),
        ],
        isStreaming: true,
        streamingMessageID: UUID(1)
      )
    ) {
      EditorFeature()
    } withDependencies: {
      $0.generationClient.cancel = { id in recordedCancel.setValue(id) }
    }

    await store.send(.cancelStreamTapped) {
      $0.isStreaming = false
    }
    await store.finish()
    XCTAssertEqual(recordedCancel.value, Self.artifact.id)
  }

  // MARK: - Model picker + restore (unchanged behavior)

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
}
