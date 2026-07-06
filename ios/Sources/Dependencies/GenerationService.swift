import Dependencies
import Foundation
import UIKit

/// App-lifetime owner of chat generations. Holds each artifact's SSE
/// connection, its delta-accumulation buffer, and the whole turn-completion
/// pipeline (HTML extraction, DB-derived version numbering, title
/// derivation, and all persistence), so a turn survives any in-app
/// navigation and a best-effort background grace window. Observers come and
/// go; at most one turn per artifact runs at a time; different artifacts run
/// concurrently.
actor GenerationService {
  private struct ActiveTurn {
    var turn: GenerationTurn
    var content = ""
    var task: Task<Void, Never>?
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    var cancelRequested = false
  }

  /// How a turn's stream ended, deciding what `finish` persists and emits.
  private enum Outcome {
    case finished
    case failed(String)
    case cancelled
  }

  private var active: [UUID: ActiveTurn] = [:]
  private var eventObservers: [UUID: [Int: AsyncStream<GenerationEvent>.Continuation]] = [:]
  private var activeSetObservers: [Int: AsyncStream<Set<UUID>>.Continuation] = [:]
  private var nextObserverID = 0

  private let openRouter: OpenRouterClient
  private let database: DatabaseClient
  private let backgroundTasks: BackgroundTaskClient
  private let uuid: UUIDGenerator
  private let date: DateGenerator

  init(
    openRouter: OpenRouterClient,
    database: DatabaseClient,
    backgroundTasks: BackgroundTaskClient,
    uuid: UUIDGenerator,
    date: DateGenerator
  ) {
    self.openRouter = openRouter
    self.database = database
    self.backgroundTasks = backgroundTasks
    self.uuid = uuid
    self.date = date
  }

  func start(_ turn: GenerationTurn) async -> Bool {
    let artifactID = turn.artifact.id
    guard active[artifactID] == nil else { return false }

    active[artifactID] = ActiveTurn(turn: turn)
    broadcastActiveSet()

    // Pre-arm the finite background window; the expiration handler checkpoints
    // partials so nothing is lost if iOS suspends us mid-stream.
    let backgroundTaskID = await backgroundTasks.begin("generation-\(artifactID)") {
      [weak self] in
      Task { await self?.checkpoint() }
    }
    // A cancel may have landed during the await above.
    guard active[artifactID] != nil else {
      await backgroundTasks.end(backgroundTaskID)
      return true
    }
    active[artifactID]?.backgroundTaskID = backgroundTaskID
    active[artifactID]?.task = Task { [weak self] in
      await self?.run(turn: turn)
    }
    return true
  }

  func cancel(artifactID: UUID) {
    guard active[artifactID] != nil else { return }
    active[artifactID]?.cancelRequested = true
    active[artifactID]?.task?.cancel()
  }

  func events(artifactID: UUID) -> AsyncStream<GenerationEvent> {
    AsyncStream { continuation in
      let observerID = nextObserverID
      nextObserverID += 1
      eventObservers[artifactID, default: [:]][observerID] = continuation
      // Snapshot first, synchronously inside the actor, so no delta can slip
      // between reading the buffer and registering the continuation.
      let snapshot = active[artifactID].map {
        GenerationSnapshot(messageID: $0.turn.assistantMessageID, partialContent: $0.content)
      }
      continuation.yield(.snapshot(snapshot))
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeEventObserver(artifactID: artifactID, observerID: observerID) }
      }
    }
  }

  func activeArtifactIDs() -> AsyncStream<Set<UUID>> {
    AsyncStream { continuation in
      let observerID = nextObserverID
      nextObserverID += 1
      activeSetObservers[observerID] = continuation
      continuation.yield(Set(active.keys))
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeActiveSetObserver(observerID) }
      }
    }
  }

  func checkpoint() async {
    for (artifactID, turn) in active where !turn.content.isEmpty {
      let message = ChatMessage(
        id: turn.turn.assistantMessageID, role: .assistant,
        content: turn.content, isFailed: true
      )
      try? await database.saveMessage(message: message, artifactID: artifactID)
    }
  }

  // MARK: - Streaming

  private func run(turn: GenerationTurn) async {
    let artifactID = turn.artifact.id

    // Start-of-turn persistence (moved here from EditorFeature.sendTapped).
    try? await database.saveMessage(message: turn.userMessage, artifactID: artifactID)
    try? await database.updateArtifact(turn.artifact)

    do {
      for try await delta in try await openRouter.streamChat(turn.request) {
        active[artifactID]?.content += delta
        broadcast(.delta(messageID: turn.assistantMessageID, text: delta), to: artifactID)
      }
      await finish(artifactID: artifactID, outcome: .finished)
    } catch {
      let cancelled = active[artifactID]?.cancelRequested ?? false
      await finish(
        artifactID: artifactID,
        outcome: cancelled ? .cancelled : .failed(error.localizedDescription)
      )
    }
  }

  private func finish(artifactID: UUID, outcome: Outcome) async {
    guard let activeTurn = active[artifactID] else { return }
    let turn = activeTurn.turn
    let content = activeTurn.content
    let assistantID = turn.assistantMessageID

    var result = GenerationResult(messageID: assistantID)

    switch outcome {
    case .finished:
      if content.isEmpty {
        // Nothing arrived — drop the placeholder bubble, persist nothing.
        break
      } else if let html = HTMLExtractor.extract(from: content) {
        let message = ChatMessage(id: assistantID, role: .assistant, content: content)
        // Version numbering is derived from the database, not editor state,
        // which may be stale or absent once generation outlives the editor.
        let lastNumber = (try? await database.fetchVersions(artifactID: artifactID))?.last?.number ?? 0
        let version = ArtifactVersion(
          id: uuid(), artifactID: artifactID, number: lastNumber + 1, html: html, createdAt: date()
        )
        var artifact = turn.artifact
        if let title = HTMLExtractor.title(from: html) { artifact.title = title }
        artifact.updatedAt = date()
        try? await database.saveMessage(message: message, artifactID: artifactID)
        try? await database.createVersion(version)
        try? await database.updateArtifact(artifact)
        result.message = message
        result.version = version
        result.artifact = artifact
      } else {
        // A plain chat turn (question answered, no app change): persist the
        // message but create no version.
        let message = ChatMessage(id: assistantID, role: .assistant, content: content)
        try? await database.saveMessage(message: message, artifactID: artifactID)
        result.message = message
      }

    case .failed(let description):
      result.errorMessage = description
      result.message = await persistFailedPartial(content, assistantID: assistantID, artifactID: artifactID)

    case .cancelled:
      result.wasCancelled = true
      result.message = await persistFailedPartial(content, assistantID: assistantID, artifactID: artifactID)
    }

    let backgroundTaskID = active[artifactID]?.backgroundTaskID ?? .invalid
    active[artifactID] = nil
    await backgroundTasks.end(backgroundTaskID)
    broadcast(.completed(result), to: artifactID)
    broadcastActiveSet()
  }

  /// Keeps any partial text visible but marked failed (so it is excluded from
  /// future context) and persists it; returns nil to drop the bubble when
  /// nothing arrived.
  private func persistFailedPartial(
    _ content: String, assistantID: UUID, artifactID: UUID
  ) async -> ChatMessage? {
    guard !content.isEmpty else { return nil }
    let message = ChatMessage(id: assistantID, role: .assistant, content: content, isFailed: true)
    try? await database.saveMessage(message: message, artifactID: artifactID)
    return message
  }

  // MARK: - Observer bookkeeping

  private func broadcast(_ event: GenerationEvent, to artifactID: UUID) {
    guard let observers = eventObservers[artifactID] else { return }
    for continuation in observers.values {
      continuation.yield(event)
    }
  }

  private func broadcastActiveSet() {
    let ids = Set(active.keys)
    for continuation in activeSetObservers.values {
      continuation.yield(ids)
    }
  }

  private func removeEventObserver(artifactID: UUID, observerID: Int) {
    eventObservers[artifactID]?[observerID] = nil
    if eventObservers[artifactID]?.isEmpty == true {
      eventObservers[artifactID] = nil
    }
  }

  private func removeActiveSetObserver(_ observerID: Int) {
    activeSetObservers[observerID] = nil
  }
}
