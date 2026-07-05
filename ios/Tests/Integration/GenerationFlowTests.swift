import ComposableArchitecture
import XCTest

@testable import PocketArtifacts

/// Integration tests: the LIVE OpenRouterClient (real URLSession, real SSE
/// parsing), real reducers, and a real in-memory GRDB database, driven
/// end-to-end against the localhost MockServer. Headless and fast enough
/// to run in the normal `xcodebuild test` CI job.
@MainActor
final class GenerationFlowTests: XCTestCase {
  func testGenerationTurnPersistsTranscriptVersionAndTitle() async throws {
    let mockServer = MockServer(scenario: .happyPath)
    let baseURL = try await mockServer.start()
    addTeardownBlock {
      await mockServer.stop()
    }

    let database = DatabaseClient.inMemory()
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let artifact = Artifact(id: UUID(), title: "Untitled", createdAt: now, updatedAt: now)
    try await database.createArtifact(artifact)

    let store = TestStore(
      initialState: EditorFeature.State(artifact: artifact, inputText: "make a tip calculator")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.openRouterClient = .live(baseURL: baseURL)
      $0.databaseClient = database
      $0.keychainClient.apiKey = { "sk-or-integration" }
      $0.uuid = .incrementing
      $0.date = .constant(now)
    }
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(\.loaded, timeout: .seconds(10))

    await store.send(.sendTapped)
    await store.receive(\.streamFinished, timeout: .seconds(10))
    await store.finish(timeout: .seconds(10))

    // The reducer saw the streamed HTML…
    XCTAssertEqual(store.state.currentHTML, Scenario.tipCalculatorHTML)
    XCTAssertEqual(store.state.artifact.title, "Tip Calculator")
    XCTAssertEqual(store.state.tab, .preview)

    // …and everything landed in SQLite.
    let versions = try await database.fetchVersions(artifactID: artifact.id)
    XCTAssertEqual(versions.count, 1)
    XCTAssertEqual(versions.first?.number, 1)
    XCTAssertEqual(versions.first?.html, Scenario.tipCalculatorHTML)

    let messages = try await database.fetchMessages(artifactID: artifact.id)
    XCTAssertEqual(messages.map(\.role), [.user, .assistant])
    XCTAssertEqual(messages.first?.content, "make a tip calculator")
    XCTAssertEqual(messages.last?.isFailed, false)

    let artifacts = try await database.fetchArtifacts()
    XCTAssertEqual(artifacts.map(\.title), ["Tip Calculator"])

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
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let artifact = Artifact(id: UUID(), title: "Untitled", createdAt: now, updatedAt: now)
    try await database.createArtifact(artifact)

    let store = TestStore(
      initialState: EditorFeature.State(artifact: artifact, inputText: "make a tip calculator")
    ) {
      EditorFeature()
    } withDependencies: {
      $0.openRouterClient = .live(baseURL: baseURL)
      $0.databaseClient = database
      $0.keychainClient.apiKey = { "sk-or-integration" }
      $0.uuid = .incrementing
      $0.date = .constant(now)
    }
    store.exhaustivity = .off

    await store.send(.sendTapped)
    await store.receive(\.streamFinished, timeout: .seconds(10))

    XCTAssertEqual(store.state.inputText, "", "input should be cleared by the first turn")
    await store.send(.binding(.set(\.inputText, "make the buttons bigger")))
    await store.send(.sendTapped)
    await store.receive(\.streamFinished, timeout: .seconds(10))
    await store.finish(timeout: .seconds(10))

    // Two versions persisted, numbered consecutively.
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

    let models = try await OpenRouterClient.live(baseURL: baseURL).listModels(apiKey: nil)
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
