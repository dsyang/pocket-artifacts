import ComposableArchitecture
import Foundation

/// The chat-driven editor for one artifact: send a prompt, watch the
/// response stream into an in-flight assistant bubble, and flip to the
/// preview tab when a new version lands. The streaming itself is owned by the
/// app-lifetime `GenerationService`, not this reducer — the editor only
/// *observes* a turn, so navigating away no longer cancels it. On appear the
/// editor subscribes to the service's per-artifact event feed (which replays
/// a snapshot of any in-flight turn, so re-entry re-attaches) and loads the
/// persisted transcript and versions.
@Reducer
struct EditorFeature {
  @ObservableState
  struct State: Equatable {
    var artifact: Artifact
    var messages: IdentifiedArrayOf<ChatMessage> = []
    /// Ordered by number ascending; the last element is the current version.
    var versions: IdentifiedArrayOf<ArtifactVersion> = []
    var inputText = ""
    var isStreaming = false
    /// ID of the assistant message currently receiving stream deltas.
    var streamingMessageID: UUID?
    var tab = Tab.chat
    var errorMessage: String?
    @Presents var versionHistory: VersionHistoryFeature.State?
    @Presents var modelPicker: ModelPickerFeature.State?

    /// The current artifact HTML, shown in Preview and Code tabs.
    var currentHTML: String? { versions.last?.html }
    /// Changes on every new version so the WKWebView knows to reload.
    var htmlVersion: Int { versions.last?.number ?? 0 }

    enum Tab: String, Equatable, CaseIterable {
      case chat = "Chat"
      case preview = "Preview"
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case task
    case loaded(messages: [ChatMessage], versions: [ArtifactVersion])
    case loadFailed(String)
    case sendTapped
    case cancelStreamTapped
    /// One event from the generation service's feed for this artifact.
    case generation(GenerationEvent)
    /// The service already had an in-flight turn for this artifact, so the
    /// optimistic bubbles are rolled back and the input restored.
    case startRejected(userMessageID: UUID, assistantMessageID: UUID, prompt: String)
    case saveFailed(String)
    case historyButtonTapped
    case modelButtonTapped
    case versionHistory(PresentationAction<VersionHistoryFeature.Action>)
    case modelPicker(PresentationAction<ModelPickerFeature.Action>)
    case delegate(Delegate)

    enum Delegate: Equatable {
      case apiKeyRequired
    }
  }

  @Dependency(\.generationClient) var generation
  @Dependency(\.keychainClient) var keychain
  @Dependency(\.databaseClient) var database
  @Dependency(\.uuid) var uuid
  @Dependency(\.date) var date

  private enum CancelID {
    case observation
  }

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        // Subscribe to the service's event feed *before* loading the
        // transcript: the snapshot (and any deltas or completion that land
        // while the load is in flight) are buffered by the stream and
        // replayed after `.loaded`, so nothing is missed on re-entry.
        return .run { [artifactID = state.artifact.id] send in
          let events = await generation.events(artifactID: artifactID)
          let messages = try await database.fetchMessages(artifactID: artifactID)
          let versions = try await database.fetchVersions(artifactID: artifactID)
          await send(.loaded(messages: messages, versions: versions))
          for await event in events {
            await send(.generation(event))
          }
        } catch: { error, send in
          await send(.loadFailed(error.localizedDescription))
        }
        .cancellable(id: CancelID.observation, cancelInFlight: true)

      case .loaded(let messages, let versions):
        state.messages = IdentifiedArray(uniqueElements: messages)
        state.versions = IdentifiedArray(uniqueElements: versions)
        return .none

      case .loadFailed(let message):
        state.errorMessage = message
        return .none

      case .sendTapped:
        let prompt = state.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !state.isStreaming else { return .none }
        guard let apiKey = keychain.apiKey() else {
          return .send(.delegate(.apiKeyRequired))
        }

        state.inputText = ""
        state.errorMessage = nil
        let userMessage = ChatMessage(id: uuid(), role: .user, content: prompt)
        state.messages.append(userMessage)
        state.artifact.updatedAt = date()

        let request = ChatRequest(
          model: state.artifact.model,
          messages: ChatContext.build(messages: Array(state.messages)),
          apiKey: apiKey
        )

        let assistantID = uuid()
        state.messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))
        state.streamingMessageID = assistantID
        state.isStreaming = true

        let turn = GenerationTurn(
          artifact: state.artifact,
          userMessage: userMessage,
          assistantMessageID: assistantID,
          request: request
        )
        return .run { send in
          let started = await generation.start(turn)
          if !started {
            await send(
              .startRejected(
                userMessageID: userMessage.id, assistantMessageID: assistantID, prompt: prompt
              )
            )
          }
        }

      case .generation(.snapshot(let snapshot)):
        guard let snapshot else {
          // Idle: make sure a stale streaming state isn't left showing.
          state.isStreaming = false
          state.streamingMessageID = nil
          return .none
        }
        // Re-attach to a turn already in flight (a re-entering editor).
        state.isStreaming = true
        state.streamingMessageID = snapshot.messageID
        if state.messages[id: snapshot.messageID] != nil {
          // A checkpoint row loaded from the DB — un-fail it and catch it up.
          state.messages[id: snapshot.messageID]?.content = snapshot.partialContent
          state.messages[id: snapshot.messageID]?.isFailed = false
        } else {
          state.messages.append(
            ChatMessage(id: snapshot.messageID, role: .assistant, content: snapshot.partialContent)
          )
        }
        return .none

      case .generation(.delta(let messageID, let text)):
        guard state.streamingMessageID == messageID else { return .none }
        state.messages[id: messageID]?.content += text
        return .none

      case .generation(.completed(let result)):
        state.isStreaming = false
        state.streamingMessageID = nil
        if let message = result.message {
          if state.messages[id: message.id] != nil {
            state.messages[id: message.id] = message
          } else {
            state.messages.append(message)
          }
        } else {
          state.messages.remove(id: result.messageID)
        }
        // The service already persisted everything; idempotently mirror the
        // result into state (a version may already be present if this editor
        // loaded it from the DB after re-entering post-completion).
        if let version = result.version, state.versions[id: version.id] == nil {
          state.versions.append(version)
          state.tab = .preview
        }
        if let artifact = result.artifact {
          state.artifact = artifact
        }
        if let errorMessage = result.errorMessage {
          state.errorMessage = errorMessage
        }
        return .none

      case let .startRejected(userMessageID, assistantMessageID, prompt):
        state.isStreaming = false
        state.streamingMessageID = nil
        state.messages.remove(id: assistantMessageID)
        state.messages.remove(id: userMessageID)
        // The incoming snapshot will re-attach us to the real in-flight turn;
        // give the user their unsent prompt back to retry afterward.
        if state.inputText.isEmpty { state.inputText = prompt }
        return .none

      case .cancelStreamTapped:
        guard state.isStreaming else { return .none }
        state.isStreaming = false
        return .run { [artifactID = state.artifact.id] _ in
          await generation.cancel(artifactID: artifactID)
        }

      case .historyButtonTapped:
        state.versionHistory = VersionHistoryFeature.State(
          versions: IdentifiedArray(uniqueElements: state.versions.reversed())
        )
        return .none

      case .modelButtonTapped:
        state.modelPicker = ModelPickerFeature.State(selectedModel: state.artifact.model)
        return .none

      case .modelPicker(.presented(.delegate(.modelSelected(let id)))):
        // Model choice is per-chat: store it on the artifact and persist.
        // The library's ordering keys off updatedAt, so picking a model
        // deliberately doesn't touch it.
        state.artifact.model = id
        return persist { [artifact = state.artifact] database in
          try await database.updateArtifact(artifact)
        }

      case .modelPicker:
        return .none

      case .versionHistory(.presented(.delegate(.restore(let version)))):
        state.versionHistory = nil
        let restored = ArtifactVersion(
          id: uuid(),
          artifactID: state.artifact.id,
          number: (state.versions.last?.number ?? 0) + 1,
          html: version.html,
          createdAt: date()
        )
        state.versions.append(restored)
        state.artifact.updatedAt = date()
        state.tab = .preview
        return persist { [artifact = state.artifact] database in
          try await database.createVersion(restored)
          try await database.updateArtifact(artifact)
        }

      case .versionHistory:
        return .none

      case .saveFailed(let message):
        state.errorMessage = message
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$versionHistory, action: \.versionHistory) {
      VersionHistoryFeature()
    }
    .ifLet(\.$modelPicker, action: \.modelPicker) {
      ModelPickerFeature()
    }
  }

  /// Runs a database write off the reducer, surfacing failures as
  /// `.saveFailed`. State is always updated first — persistence follows it.
  private func persist(
    _ operation: @escaping @Sendable (DatabaseClient) async throws -> Void
  ) -> Effect<Action> {
    .run { _ in
      try await operation(database)
    } catch: { error, send in
      await send(.saveFailed(error.localizedDescription))
    }
  }
}
