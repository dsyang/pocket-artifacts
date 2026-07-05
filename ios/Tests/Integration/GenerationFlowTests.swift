import ComposableArchitecture
import XCTest

@testable import PocketArtifacts

/// Integration tests: the LIVE OpenRouterClient (real URLSession, real SSE
/// parsing), real reducers, and a real in-memory GRDB database, driven
/// end-to-end against the localhost MockServer. Headless and fast enough
/// to run in the normal `xcodebuild test` CI job.
///
/// These drive a real `Store` (not `TestStore`): integration asserts final
/// state + persisted rows + request payloads, not action-by-action
/// bookkeeping. `send(...).finish()` awaits the effects of that send;
/// writes spawned by downstream actions (e.g. the persist effect of
/// `.streamFinished`) are awaited by polling the database.
@MainActor
final class GenerationFlowTests: XCTestCase {
  static let now = Date(timeIntervalSince1970: 1_750_000_000)

  private func makeStore(
    database: DatabaseClient,
    baseURL: URL,
    artifact: Artifact,
    inputText: String
  ) -> StoreOf<EditorFeature> {
    Store(initialState: EditorFeature.State(artifact: artifact, inputText: inputText)) {
      EditorFeature()
    } withDependencies: {
      $0.openRouterClient = .live(baseURL: baseURL)
      $0.databaseClient = database
      $0.keychainClient.apiKey = { "sk-or-integration" }
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
    }
  }

  /// Polls until the condition holds; a throwing condition counts as false
  /// (call sites use `try?`) so transient states just keep the poll going.
  private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 10,
    _ condition: () async -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for \(description)")
  }

  func testGenerationTurnPersistsTranscriptVersionAndTitle() async throws {
    let mockServer = MockServer(scenario: .happyPath)
    let baseURL = try await mockServer.start()
    addTeardownBlock {
      await mockServer.stop()
    }

    let database = DatabaseClient.inMemory()
    let artifact = Artifact(
      id: UUID(100), title: "Untitled", createdAt: Self.now, updatedAt: Self.now
    )
    try await database.createArtifact(artifact)

    let store = makeStore(
      database: database, baseURL: baseURL, artifact: artifact,
      inputText: "make a tip calculator"
    )

    // Loading an empty artifact: no messages, no versions.
    await store.send(.task).finish()
    XCTAssertTrue(store.withState(\.messages).isEmpty)
    XCTAssertTrue(store.withState(\.versions).isEmpty)

    // One full generation turn: request → SSE stream → extraction.
    await store.send(.sendTapped).finish()

    XCTAssertEqual(store.withState(\.currentHTML), Scenario.tipCalculatorHTML)
    XCTAssertEqual(store.withState(\.artifact.title), "Tip Calculator")
    XCTAssertEqual(store.withState(\.tab), .preview)
    XCTAssertNil(store.withState(\.errorMessage))

    // …and everything lands in SQLite (the persist effect spawned by
    // .streamFinished may still be in flight, so poll).
    await waitUntil("version row persisted") {
      (try? await database.fetchVersions(artifactID: artifact.id))?.count == 1
    }
    let versions = try await database.fetchVersions(artifactID: artifact.id)
    XCTAssertEqual(versions.first?.number, 1)
    XCTAssertEqual(versions.first?.html, Scenario.tipCalculatorHTML)

    await waitUntil("transcript persisted") {
      (try? await database.fetchMessages(artifactID: artifact.id))?.count == 2
    }
    let messages = try await database.fetchMessages(artifactID: artifact.id)
    XCTAssertEqual(messages.map(\.role), [.user, .assistant])
    XCTAssertEqual(messages.first?.content, "make a tip calculator")
    XCTAssertEqual(messages.last?.isFailed, false)

    await waitUntil("artifact retitled") {
      (try? await database.fetchArtifacts())?.map(\.title) == ["Tip Calculator"]
    }

    // The request OpenRouter received was well-formed: streaming on, system
    // prompt first, then the user turn.
    let bodies = await mockServer.chatRequestBodies
    XCTAssertEqual(bodies.count, 1)
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any]
    )
    XCTAssertEqual(payload["stream"] as? Bool, true)
    XCTAssertEqual(payload["model"] as? String, OpenRouterClient.defaultModel)
    let sentMessages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    XCTAssertEqual(sentMessages.map { $0["role"] as? String }, ["system", "user"])
    XCTAssertEqual(sentMessages.first?["content"] as? String, ArtifactPrompt.system)
    XCTAssertEqual(sentMessages.last?["content"] as? String, "make a tip calculator")
  }

  func testRefinementTurnSendsPriorHTMLAndIncrementsVersion() async throws {
    let mockServer = MockServer(scenario: .happyPath)
    let baseURL = try await mockServer.start()
    addTeardownBlock {
      await mockServer.stop()
    }

    let database = DatabaseClient.inMemory()
    let artifact = Artifact(
      id: UUID(101), title: "Untitled", createdAt: Self.now, updatedAt: Self.now
    )
    try await database.createArtifact(artifact)

    let store = makeStore(
      database: database, baseURL: baseURL, artifact: artifact,
      inputText: "make a tip calculator"
    )

    await store.send(.sendTapped).finish()
    await waitUntil("first version persisted") {
      (try? await database.fetchVersions(artifactID: artifact.id))?.count == 1
    }

    XCTAssertEqual(store.withState(\.inputText), "", "input is cleared by the first turn")
    store.send(.binding(.set(\.inputText, "make the buttons bigger")))
    await store.send(.sendTapped).finish()

    // Two versions persisted, numbered consecutively.
    await waitUntil("second version persisted") {
      (try? await database.fetchVersions(artifactID: artifact.id))?.count == 2
    }
    let versions = try await database.fetchVersions(artifactID: artifact.id)
    XCTAssertEqual(versions.map(\.number), [1, 2])

    // The refinement request carried the previous assistant turn with its
    // HTML intact (it is the latest version, so it is not placeholdered).
    let bodies = await mockServer.chatRequestBodies
    XCTAssertEqual(bodies.count, 2)
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any]
    )
    let sentMessages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    XCTAssertEqual(
      sentMessages.map { $0["role"] as? String },
      ["system", "user", "assistant", "user"]
    )
    let assistantContent = try XCTUnwrap(sentMessages[2]["content"] as? String)
    XCTAssertTrue(assistantContent.contains(Scenario.tipCalculatorHTML))
  }

  func testListModelsAgainstMockServer() async throws {
    let mockServer = MockServer(scenario: .noFence)
    let baseURL = try await mockServer.start()
    addTeardownBlock {
      await mockServer.stop()
    }

    // The category query (used by the picker's default curated mode) must
    // not break routing; the mock serves the same list either way.
    let models = try await OpenRouterClient.live(baseURL: baseURL)
      .listModels(apiKey: nil, category: OpenRouterClient.programmingCategory)
    XCTAssertEqual(
      models.map(\.id),
      [
        "anthropic/claude-sonnet-4.5",
        "no-name/model-without-name",
        "openai/gpt-5",
      ]
    )
    // Entries without a display name fall back to the id, and the list is
    // sorted by name.
    XCTAssertEqual(models[1].name, "no-name/model-without-name")
  }
}
