import ComposableArchitecture
import UIKit
import XCTest

@testable import PocketArtifacts

/// Direct async tests of the app-lifetime `GenerationService` actor — the
/// owner of streaming, the completion pipeline, and all persistence. These
/// absorb the persistence half of what the editor's TestStore suite used to
/// cover, plus the behaviors that only exist now that generation outlives
/// the editor: re-attach snapshots, concurrent artifacts, and the
/// background-task grace window.
final class GenerationServiceTests: XCTestCase {
  static let now = Date(timeIntervalSince1970: 1_234_567_890)
  static let html =
    "<!DOCTYPE html>\n<html><head><title>Tip Calculator</title></head><body><h1>Tips</h1></body></html>"

  // MARK: - Fixtures

  private func makeService(
    database: DatabaseClient,
    backgroundTasks: BackgroundTaskClient = BackgroundTaskClient(
      begin: { _, _ in .invalid }, end: { _ in }
    ),
    streamChat: @escaping @Sendable (ChatRequest) async throws -> AsyncThrowingStream<String, Error>
  ) -> GenerationService {
    var openRouter = OpenRouterClient.testValue
    openRouter.streamChat = streamChat
    return GenerationService(
      openRouter: openRouter,
      database: database,
      backgroundTasks: backgroundTasks,
      uuid: .incrementing,
      date: .constant(Self.now)
    )
  }

  private func makeArtifact(id: UUID = UUID(100)) -> Artifact {
    Artifact(id: id, title: "Untitled", createdAt: Self.now, updatedAt: Self.now)
  }

  private func makeTurn(
    artifact: Artifact,
    prompt: String = "make a tip calculator",
    userID: UUID = UUID(500),
    assistantID: UUID = UUID(501)
  ) -> GenerationTurn {
    GenerationTurn(
      artifact: artifact,
      userMessage: ChatMessage(id: userID, role: .user, content: prompt),
      assistantMessageID: assistantID,
      request: ChatRequest(model: artifact.model, messages: [], apiKey: "sk-or-test")
    )
  }

  /// An all-at-once stream: yields each delta then finishes.
  private func scriptedStream(
    _ deltas: [String],
    throwing error: Error? = nil
  ) -> @Sendable (ChatRequest) async throws -> AsyncThrowingStream<String, Error> {
    { _ in
      AsyncThrowingStream { continuation in
        for delta in deltas { continuation.yield(delta) }
        continuation.finish(throwing: error)
      }
    }
  }

  /// Subscribes, starts the turn, and drains events until `.completed`.
  private func runToCompletion(
    _ service: GenerationService, _ turn: GenerationTurn
  ) async -> [GenerationEvent] {
    let stream = await service.events(artifactID: turn.artifact.id)
    let started = await service.start(turn)
    XCTAssertTrue(started)
    var events: [GenerationEvent] = []
    for await event in stream {
      events.append(event)
      if case .completed = event { break }
    }
    return events
  }

  private func deltaTexts(_ events: [GenerationEvent]) -> [String] {
    events.compactMap { if case .delta(_, let text) = $0 { return text } else { return nil } }
  }

  private func completed(in events: [GenerationEvent]) -> GenerationResult? {
    for event in events {
      if case .completed(let result) = event { return result }
    }
    return nil
  }

  // MARK: - Happy path

  func testHappyPathEmitsEventsAndPersistsVersion() async throws {
    let database = DatabaseClient.inMemory()
    let artifact = makeArtifact()
    try await database.createArtifact(artifact)

    let delta1 = "Here's your app!\n"
    let delta2 = "```html\n\(Self.html)\n```\nEnjoy!"
    let service = makeService(database: database, streamChat: scriptedStream([delta1, delta2]))
    let turn = makeTurn(artifact: artifact)

    let events = await runToCompletion(service, turn)

    XCTAssertEqual(events.first, .snapshot(nil))
    XCTAssertEqual(deltaTexts(events), [delta1, delta2])
    let result = try XCTUnwrap(completed(in: events))
    XCTAssertEqual(result.messageID, turn.assistantMessageID)
    XCTAssertEqual(result.version?.number, 1)
    XCTAssertEqual(result.version?.html, Self.html)
    XCTAssertEqual(result.artifact?.title, "Tip Calculator")
    XCTAssertEqual(result.message?.isFailed, false)

    // Everything landed in SQLite: user + assistant messages, one version,
    // the retitled artifact.
    let messages = try await database.fetchMessages(artifactID: artifact.id)
    XCTAssertEqual(messages.map(\.role), [.user, .assistant])
    XCTAssertEqual(messages.last?.content, delta1 + delta2)
    let versions = try await database.fetchVersions(artifactID: artifact.id)
    XCTAssertEqual(versions.map(\.number), [1])
    let titles = try await database.fetchArtifacts().map(\.title)
    XCTAssertEqual(titles, ["Tip Calculator"])
  }

  func testVersionNumberIsDerivedFromDatabase() async throws {
    let database = DatabaseClient.inMemory()
    let artifact = makeArtifact()
    try await database.createArtifact(artifact)
    // Seed a higher existing version with no editor state involved at all.
    try await database.createVersion(
      ArtifactVersion(
        id: UUID(90), artifactID: artifact.id, number: 3, html: "<p>old</p>", createdAt: Self.now
      )
    )

    let service = makeService(
      database: database, streamChat: scriptedStream(["```html\n\(Self.html)\n```"])
    )
    let events = await runToCompletion(service, makeTurn(artifact: artifact))

    XCTAssertEqual(completed(in: events)?.version?.number, 4)
    let versions = try await database.fetchVersions(artifactID: artifact.id)
    XCTAssertEqual(versions.map(\.number), [3, 4])
  }

  func testNoFencePersistsMessageWithoutVersion() async throws {
    let database = DatabaseClient.inMemory()
    let artifact = makeArtifact()
    try await database.createArtifact(artifact)

    let reply = "I can build small single-page apps. What would you like?"
    let service = makeService(database: database, streamChat: scriptedStream([reply]))
    let events = await runToCompletion(service, makeTurn(artifact: artifact))

    let result = try XCTUnwrap(completed(in: events))
    XCTAssertNil(result.version)
    XCTAssertEqual(result.message?.content, reply)
    XCTAssertEqual(result.message?.isFailed, false)
    let versions = try await database.fetchVersions(artifactID: artifact.id)
    XCTAssertTrue(versions.isEmpty)
    let messages = try await database.fetchMessages(artifactID: artifact.id)
    XCTAssertEqual(messages.map(\.content), ["make a tip calculator", reply])
  }

  func testEmptyResponseDropsPlaceholderAndPersistsNoAssistantMessage() async throws {
    let database = DatabaseClient.inMemory()
    let artifact = makeArtifact()
    try await database.createArtifact(artifact)

    let service = makeService(database: database, streamChat: scriptedStream([]))
    let events = await runToCompletion(service, makeTurn(artifact: artifact))

    XCTAssertNil(completed(in: events)?.message)
    // Only the user message was persisted; the empty bubble is dropped.
    let messages = try await database.fetchMessages(artifactID: artifact.id)
    XCTAssertEqual(messages.map(\.role), [.user])
  }

  // MARK: - Failure & cancel

  func testFailureMarksPartialFailedAndReportsError() async throws {
    struct StreamError: Error {}
    let database = DatabaseClient.inMemory()
    let artifact = makeArtifact()
    try await database.createArtifact(artifact)

    let service = makeService(
      database: database, streamChat: scriptedStream(["Let me start"], throwing: StreamError())
    )
    let events = await runToCompletion(service, makeTurn(artifact: artifact))

    let result = try XCTUnwrap(completed(in: events))
    XCTAssertEqual(result.errorMessage, StreamError().localizedDescription)
    XCTAssertEqual(result.message?.isFailed, true)
    XCTAssertEqual(result.message?.content, "Let me start")
    let messages = try await database.fetchMessages(artifactID: artifact.id)
    XCTAssertEqual(messages.last?.isFailed, true)
  }

  func testCancelTerminatesStreamAndMarksPartialFailed() async throws {
    let database = DatabaseClient.inMemory()
    let artifact = makeArtifact()
    try await database.createArtifact(artifact)

    // A stream that yields once and then never finishes — the cancel drives
    // termination.
    let streamContinuation =
      LockIsolated<AsyncThrowingStream<String, Error>.Continuation?>(nil)
    let terminated = LockIsolated(false)
    let service = makeService(database: database) { _ in
      AsyncThrowingStream { continuation in
        continuation.onTermination = { _ in terminated.setValue(true) }
        streamContinuation.setValue(continuation)
      }
    }
    let turn = makeTurn(artifact: artifact)

    let stream = await service.events(artifactID: artifact.id)
    _ = await service.start(turn)
    while streamContinuation.value == nil { await Task.yield() }
    streamContinuation.value?.yield("Working on")

    var events: [GenerationEvent] = []
    for await event in stream {
      events.append(event)
      if case .delta = event { await service.cancel(artifactID: artifact.id) }
      if case .completed = event { break }
    }

    let result = try XCTUnwrap(completed(in: events))
    XCTAssertTrue(result.wasCancelled)
    XCTAssertEqual(result.message?.isFailed, true)
    XCTAssertEqual(result.message?.content, "Working on")
    // The underlying stream is torn down as part of cancellation (onTermination
    // fires around the nil return); poll to avoid racing that teardown.
    try await waitFor("underlying stream torn down") { terminated.value }
  }

  // MARK: - Re-attach

  func testLateSubscriberGetsSnapshotOfAccumulatedContent() async throws {
    let database = DatabaseClient.inMemory()
    let artifact = makeArtifact()
    try await database.createArtifact(artifact)

    let streamContinuation =
      LockIsolated<AsyncThrowingStream<String, Error>.Continuation?>(nil)
    let service = makeService(database: database) { _ in
      AsyncThrowingStream { streamContinuation.setValue($0) }
    }
    let turn = makeTurn(artifact: artifact)

    // Primary subscriber, used only to know when the deltas were processed.
    let primary = await service.events(artifactID: artifact.id)
    var primaryIterator = primary.makeAsyncIterator()
    let primaryFirst = await primaryIterator.next()
    XCTAssertEqual(primaryFirst, .snapshot(nil))

    _ = await service.start(turn)
    while streamContinuation.value == nil { await Task.yield() }
    streamContinuation.value?.yield("Hello ")
    streamContinuation.value?.yield("world")

    var deltasSeen = 0
    while deltasSeen < 2 {
      if case .delta = await primaryIterator.next() { deltasSeen += 1 }
    }

    // A late subscriber (a re-entering editor) gets the accumulated partial.
    let late = await service.events(artifactID: artifact.id)
    var lateIterator = late.makeAsyncIterator()
    let lateFirst = await lateIterator.next()
    XCTAssertEqual(
      lateFirst,
      .snapshot(GenerationSnapshot(messageID: turn.assistantMessageID, partialContent: "Hello world"))
    )

    streamContinuation.value?.finish()
  }

  // MARK: - Concurrency

  func testConcurrentArtifactsRunIndependently() async throws {
    let database = DatabaseClient.inMemory()
    let artifactA = makeArtifact(id: UUID(100))
    let artifactB = makeArtifact(id: UUID(200))
    try await database.createArtifact(artifactA)
    try await database.createArtifact(artifactB)

    // Each artifact routes to its own scripted HTML by request model tag.
    let htmlA = "<html><head><title>A</title></head><body>A</body></html>"
    let htmlB = "<html><head><title>B</title></head><body>B</body></html>"
    // `let` copies (not mutated vars) so the async-let captures are Sendable.
    let artifactAModel = Artifact(
      id: artifactA.id, title: artifactA.title, model: "model-a",
      createdAt: Self.now, updatedAt: Self.now
    )
    let artifactBModel = Artifact(
      id: artifactB.id, title: artifactB.title, model: "model-b",
      createdAt: Self.now, updatedAt: Self.now
    )

    let service = makeService(database: database) { request in
      let html = request.model == "model-a" ? htmlA : htmlB
      return AsyncThrowingStream { continuation in
        continuation.yield("```html\n\(html)\n```")
        continuation.finish()
      }
    }

    async let eventsA = runToCompletion(service, makeTurn(artifact: artifactAModel, assistantID: UUID(1)))
    async let eventsB = runToCompletion(service, makeTurn(artifact: artifactBModel, assistantID: UUID(2)))
    let (collectedA, collectedB) = await (eventsA, eventsB)

    XCTAssertEqual(completed(in: collectedA)?.artifact?.title, "A")
    XCTAssertEqual(completed(in: collectedB)?.artifact?.title, "B")
    // Event isolation: A's feed only ever mentions A's assistant message.
    for event in collectedA {
      if case .delta(let id, _) = event { XCTAssertEqual(id, UUID(1)) }
    }
    for event in collectedB {
      if case .delta(let id, _) = event { XCTAssertEqual(id, UUID(2)) }
    }
  }

  func testStartRefusedWhenArtifactAlreadyGenerating() async throws {
    let database = DatabaseClient.inMemory()
    let artifact = makeArtifact()
    try await database.createArtifact(artifact)

    let streamContinuation =
      LockIsolated<AsyncThrowingStream<String, Error>.Continuation?>(nil)
    let service = makeService(database: database) { _ in
      AsyncThrowingStream { streamContinuation.setValue($0) }
    }

    let first = await service.start(makeTurn(artifact: artifact, assistantID: UUID(1)))
    XCTAssertTrue(first)
    let second = await service.start(makeTurn(artifact: artifact, assistantID: UUID(2)))
    XCTAssertFalse(second, "a second start for the same artifact is refused")

    streamContinuation.value?.finish()
  }

  func testActiveArtifactIDsReflectsLifecycle() async throws {
    let database = DatabaseClient.inMemory()
    let artifact = makeArtifact()
    try await database.createArtifact(artifact)

    let streamContinuation =
      LockIsolated<AsyncThrowingStream<String, Error>.Continuation?>(nil)
    let service = makeService(database: database) { _ in
      AsyncThrowingStream { streamContinuation.setValue($0) }
    }

    let active = await service.activeArtifactIDs()
    var iterator = active.makeAsyncIterator()
    let initial = await iterator.next()
    XCTAssertEqual(initial, Set<UUID>())

    _ = await service.start(makeTurn(artifact: artifact))
    let afterStart = await iterator.next()
    XCTAssertEqual(afterStart, Set([artifact.id]))

    while streamContinuation.value == nil { await Task.yield() }
    streamContinuation.value?.finish()
    let afterFinish = await iterator.next()
    XCTAssertEqual(afterFinish, Set<UUID>())
  }

  // MARK: - Background task

  func testBackgroundTaskBracketsGenerationAndExpirationCheckpoints() async throws {
    let database = DatabaseClient.inMemory()
    let artifact = makeArtifact()
    try await database.createArtifact(artifact)

    let beginNames = LockIsolated<[String]>([])
    let endedIDs = LockIsolated<[UIBackgroundTaskIdentifier]>([])
    let expiration = LockIsolated<(@Sendable () -> Void)?>(nil)
    let backgroundTasks = BackgroundTaskClient(
      begin: { name, onExpiration in
        beginNames.withValue { $0.append(name) }
        expiration.setValue(onExpiration)
        return UIBackgroundTaskIdentifier(rawValue: 42)
      },
      end: { id in endedIDs.withValue { $0.append(id) } }
    )

    let streamContinuation =
      LockIsolated<AsyncThrowingStream<String, Error>.Continuation?>(nil)
    let service = makeService(database: database, backgroundTasks: backgroundTasks) { _ in
      AsyncThrowingStream { streamContinuation.setValue($0) }
    }
    let turn = makeTurn(artifact: artifact)

    let stream = await service.events(artifactID: artifact.id)
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()
    XCTAssertEqual(first, .snapshot(nil))
    _ = await service.start(turn)
    while streamContinuation.value == nil { await Task.yield() }

    XCTAssertEqual(beginNames.value, ["generation-\(artifact.id)"])

    // Partway through: a fenced-but-incomplete response.
    streamContinuation.value?.yield("```html\n\(Self.html)")
    // Drain the delta so we know the service accumulated it.
    while true {
      if case .delta = await iterator.next() { break }
    }

    // iOS is about to suspend us: the expiration handler checkpoints partials.
    expiration.value?()
    try await waitFor("checkpoint persisted as failed") {
      let messages = try? await database.fetchMessages(artifactID: artifact.id)
      return messages?.first(where: { $0.role == .assistant })?.isFailed == true
    }

    // The stream then completes normally; the final save overwrites the
    // checkpoint (same message id) with the un-failed final content, and the
    // background task is ended.
    streamContinuation.value?.yield("\n```")
    streamContinuation.value?.finish()
    while true {
      if case .completed = await iterator.next() { break }
    }
    let messages = try await database.fetchMessages(artifactID: artifact.id)
    let assistant = try XCTUnwrap(messages.first(where: { $0.role == .assistant }))
    XCTAssertFalse(assistant.isFailed)
    XCTAssertEqual(endedIDs.value, [UIBackgroundTaskIdentifier(rawValue: 42)])
  }

  /// Polls until the async condition holds or the timeout elapses.
  private func waitFor(
    _ description: String,
    timeout: TimeInterval = 5,
    _ condition: () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(description)")
  }
}
