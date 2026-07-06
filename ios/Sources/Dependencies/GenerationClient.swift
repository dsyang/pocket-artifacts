import Dependencies
import DependenciesMacros
import Foundation

/// Everything the service needs to run one turn. The editor builds this —
/// it owns the transcript and the Keychain check — and hands the connection
/// off to the service, which owns everything from the first byte onward.
struct GenerationTurn: Equatable, Sendable {
  var artifact: Artifact
  var userMessage: ChatMessage
  /// Pre-assigned by the editor so it can show the placeholder bubble
  /// immediately and match incoming deltas to it.
  var assistantMessageID: UUID
  var request: ChatRequest
}

/// Accumulated state of an in-flight turn, replayed to a late subscriber so
/// a re-entering editor can catch up before live deltas resume.
struct GenerationSnapshot: Equatable, Sendable {
  var messageID: UUID
  var partialContent: String
}

/// The outcome of a finished turn. Everything referenced here is already in
/// the database when the event is emitted — observers only mirror it into
/// their UI state, they never persist.
struct GenerationResult: Equatable, Sendable {
  var messageID: UUID
  /// The assistant message as persisted; nil when nothing arrived and the
  /// placeholder bubble should be dropped.
  var message: ChatMessage? = nil
  /// Created when the response carried an HTML fence; nil for plain chat
  /// turns, failures, and cancellations.
  var version: ArtifactVersion? = nil
  /// The artifact as persisted (retitled/touched); nil when untouched.
  var artifact: Artifact? = nil
  var errorMessage: String? = nil
  var wasCancelled: Bool = false
}

/// The per-artifact event feed a subscriber sees: a snapshot first, then
/// live deltas, then a completion.
enum GenerationEvent: Equatable, Sendable {
  /// Always the first event on a subscription: the in-flight turn for this
  /// artifact, or nil when idle. Lets a re-entering editor re-attach.
  case snapshot(GenerationSnapshot?)
  case delta(messageID: UUID, text: String)
  case completed(GenerationResult)
}

/// TCA dependency in front of the app-lifetime `GenerationService`. The live
/// value wraps a single shared actor so generations survive any in-app
/// navigation; tests inject a service built around a MockServer + in-memory
/// database, or stub the endpoints directly.
@DependencyClient
struct GenerationClient: Sendable {
  /// Starts a turn; returns false (with no side effects) when this artifact
  /// already has one in flight. Persists the user message before streaming.
  var start: @Sendable (GenerationTurn) async -> Bool = { _ in false }
  var cancel: @Sendable (_ artifactID: UUID) async -> Void
  /// Per-artifact event feed: a snapshot first, then live events. Stays open
  /// across turns until the consumer's iteration is cancelled (e.g. a pop).
  var events: @Sendable (_ artifactID: UUID) async -> AsyncStream<GenerationEvent> = { _ in
    AsyncStream { $0.finish() }
  }
  /// The current, then every subsequent, set of artifact IDs with an active
  /// generation. Emits the current set immediately; drives the library
  /// "generating" indicator.
  var activeArtifactIDs: @Sendable () async -> AsyncStream<Set<UUID>> = {
    AsyncStream { $0.finish() }
  }
  /// Persists the partial content of every in-flight turn (marked failed so a
  /// process death reads as an interrupted turn; a later finish overwrites).
  var checkpoint: @Sendable () async -> Void
}

extension GenerationClient: DependencyKey {
  // Must be `static let`: swift-dependencies resolves the live value through
  // this stored property, so a computed `var` would mint a fresh service —
  // and orphan every running generation — on each access.
  static let liveValue = GenerationClient.live(
    service: GenerationService(
      openRouter: .liveValue,
      database: .liveValue,
      backgroundTasks: .liveValue,
      uuid: UUIDGenerator { UUID() },
      date: DateGenerator { Date() }
    )
  )

  static func live(service: GenerationService) -> GenerationClient {
    GenerationClient(
      start: { await service.start($0) },
      cancel: { await service.cancel(artifactID: $0) },
      events: { await service.events(artifactID: $0) },
      activeArtifactIDs: { await service.activeArtifactIDs() },
      checkpoint: { await service.checkpoint() }
    )
  }

  static let testValue = GenerationClient()
}

extension DependencyValues {
  var generationClient: GenerationClient {
    get { self[GenerationClient.self] }
    set { self[GenerationClient.self] = newValue }
  }
}
