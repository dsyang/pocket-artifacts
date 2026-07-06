import ComposableArchitecture
import XCTest

@testable import PocketArtifacts

/// Integration tests: the LIVE OpenRouterClient (real URLSession, real SSE
/// parsing) driving the real `GenerationService` and reducers against a
/// localhost MockServer with an in-memory GRDB database. Headless and fast
/// enough for the normal `xcodebuild test` CI job.
///
/// Generation is now owned by the app-lifetime service, not an editor
/// effect, so these assert final persisted rows + request payloads by
/// polling (the completion runs asynchronously in the service after
/// `start` returns).
@MainActor
final class GenerationFlowTests: XCTestCase {
  static let now = Date(timeIntervalSince1970: 1_750_000_000)

  private func makeService(database: DatabaseClient, baseURL: URL) -> GenerationService {
    GenerationService(
      openRouter: .live(baseURL: baseURL),
      database: database,
      backgroundTasks: BackgroundTaskClient(begin: { _, _ in .invalid }, end: { _ in }),
      uuid: .incrementing,
      date: .constant(Self.now)
    )
  }

  private func makeEditorStore(
    service: GenerationService,
    database: DatabaseClient,
    artifact: Artifact,
    inputText: String = ""
  ) -> StoreOf<EditorFeature> {
    Store(initialState: EditorFeature.State(artifact: artifact, inputText: inputText)) {
      EditorFeature()
    } withDependencies: {
      $0.generationClient = .live(service: service)
      $0.databaseClient = database
      $0.keychainClient.apiKey = { "sk-or-integration" }
      $0.uuid = .incrementing
      $0.date = .constant(Self.now)
    }
  }

  /// Polls until the condition holds; a throwing condition counts as false
  /// so transient states just keep the poll going.
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

  // MARK: - Live pipeline → service → database

  func testLiveGenerationPipelinePersistsTranscriptVersionAndTitle() async throws {
    let mockServer = MockServer(scenario: .happyPath)
    let baseURL = try await mockServer.start()
    addTeardownBlock { await mockServer.stop() }

    let database = DatabaseClient.inMemory()
    let artifact = Artifact(
      id: UUID(100), title: "Untitled", createdAt: Self.now, updatedAt: Self.now
    )
    try await database.createArtifact(artifact)

    // Drive the service directly: live client → real SSE → extraction →
    // persistence, exactly as it runs decoupled from any editor.
    let service = makeService(database: database, baseURL: baseURL)
    let userMessage = ChatMessage(id: UUID(500), role: .user, content: "make a tip calculator")
    let request = ChatRequest(
      model: artifact.model,
      messages: ChatContext.build(messages: [userMessage]),
      apiKey: "sk-or-integration"
    )
    let started = await service.start(
      GenerationTurn(
        artifact: artifact, userMessage: userMessage, assistantMessageID: UUID(501),
        request: request
      )
    )
    XCTAssertTrue(started)

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

    // The request OpenRouter received was well-formed.
    let bodies = await mockServer.chatRequestBodies
    XCTAssertEqual(bodies.count, 1)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
    XCTAssertEqual(payload["stream"] as? Bool, true)
    XCTAssertEqual(payload["model"] as? String, OpenRouterClient.defaultModel)
    let sentMessages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    XCTAssertEqual(sentMessages.map { $0["role"] as? String }, ["system", "user"])
    XCTAssertEqual(sentMessages.first?["content"] as? String, ArtifactPrompt.system)
    XCTAssertEqual(sentMessages.last?["content"] as? String, "make a tip calculator")
  }

  // MARK: - Editor re-attach through the live path (pop-survival)

  func testEditorObservesGenerationStartedOutsideIt() async throws {
    let mockServer = MockServer(scenario: .happyPath)
    let baseURL = try await mockServer.start()
    addTeardownBlock { await mockServer.stop() }

    let database = DatabaseClient.inMemory()
    let artifact = Artifact(
      id: UUID(101), title: "Untitled", createdAt: Self.now, updatedAt: Self.now
    )
    try await database.createArtifact(artifact)

    // A turn is started on the service with no editor attached — the same
    // situation as a generation still running after its editor was popped.
    let service = makeService(database: database, baseURL: baseURL)
    let userMessage = ChatMessage(id: UUID(500), role: .user, content: "make a tip calculator")
    _ = await service.start(
      GenerationTurn(
        artifact: artifact, userMessage: userMessage, assistantMessageID: UUID(501),
        request: ChatRequest(
          model: artifact.model,
          messages: ChatContext.build(messages: [userMessage]),
          apiKey: "sk-or-integration"
        )
      )
    )

    // A (re-)entering editor subscribes and converges on the finished turn,
    // whether it re-attaches to the in-flight stream or loads the completed
    // transcript.
    let store = makeEditorStore(service: service, database: database, artifact: artifact)
    store.send(.task)
    await waitUntil("editor reflects the generated artifact") {
      store.withState(\.currentHTML) == Scenario.tipCalculatorHTML
    }
    XCTAssertEqual(store.withState(\.artifact.title), "Tip Calculator")
    XCTAssertFalse(store.withState(\.isStreaming))
  }

  // MARK: - Refinement builds context from the loaded transcript

  func testRefinementTurnSendsPriorHTMLAndIncrementsVersion() async throws {
    let mockServer = MockServer(scenario: .happyPath)
    let baseURL = try await mockServer.start()
    addTeardownBlock { await mockServer.stop() }

    let database = DatabaseClient.inMemory()
    let artifact = Artifact(
      id: UUID(102), title: "Untitled", createdAt: Self.now, updatedAt: Self.now
    )
    try await database.createArtifact(artifact)
    let service = makeService(database: database, baseURL: baseURL)

    // Turn 1 straight through the service.
    let userMessage = ChatMessage(id: UUID(500), role: .user, content: "make a tip calculator")
    _ = await service.start(
      GenerationTurn(
        artifact: artifact, userMessage: userMessage, assistantMessageID: UUID(501),
        request: ChatRequest(
          model: artifact.model,
          messages: ChatContext.build(messages: [userMessage]),
          apiKey: "sk-or-integration"
        )
      )
    )
    await waitUntil("first version persisted") {
      (try? await database.fetchVersions(artifactID: artifact.id))?.count == 1
    }

    // The editor loads that transcript, then a second turn is sent through it
    // so its ChatContext carries the prior assistant HTML.
    let store = makeEditorStore(service: service, database: database, artifact: artifact)
    store.send(.task)
    await waitUntil("editor loaded the first version") {
      store.withState(\.versions).count == 1
    }

    store.send(.binding(.set(\.inputText, "make the buttons bigger")))
    await store.send(.sendTapped).finish()

    await waitUntil("second version persisted") {
      (try? await database.fetchVersions(artifactID: artifact.id))?.count == 2
    }
    let versions = try await database.fetchVersions(artifactID: artifact.id)
    XCTAssertEqual(versions.map(\.number), [1, 2])

    let bodies = await mockServer.chatRequestBodies
    XCTAssertEqual(bodies.count, 2)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
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
    addTeardownBlock { await mockServer.stop() }

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
    XCTAssertEqual(models[1].name, "no-name/model-without-name")
  }
}
