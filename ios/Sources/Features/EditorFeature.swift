import ComposableArchitecture
import Foundation

/// The chat-driven editor for one artifact: send a prompt, stream the
/// response into an in-flight assistant bubble, extract the HTML fence when
/// the stream finishes, persist a new version, and flip to the preview tab.
/// The transcript and versions are loaded from the database on appear.
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
    var model = OpenRouterClient.defaultModel
    @Presents var versionHistory: VersionHistoryFeature.State?

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
    case streamDelta(String)
    case streamFinished
    case streamFailed(String)
    case saveFailed(String)
    case historyButtonTapped
    case versionHistory(PresentationAction<VersionHistoryFeature.Action>)
    case delegate(Delegate)

    enum Delegate: Equatable {
      case apiKeyRequired
    }
  }

  @Dependency(\.openRouterClient) var openRouter
  @Dependency(\.keychainClient) var keychain
  @Dependency(\.databaseClient) var database
  @Dependency(\.modelPreference) var modelPreference
  @Dependency(\.uuid) var uuid
  @Dependency(\.date) var date

  private enum CancelID {
    case stream
  }

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        state.model = modelPreference.selectedModel() ?? OpenRouterClient.defaultModel
        return .run { [artifactID = state.artifact.id] send in
          let messages = try await database.fetchMessages(artifactID: artifactID)
          let versions = try await database.fetchVersions(artifactID: artifactID)
          await send(.loaded(messages: messages, versions: versions))
        } catch: { error, send in
          await send(.loadFailed(error.localizedDescription))
        }

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

        state.model = modelPreference.selectedModel() ?? OpenRouterClient.defaultModel
        state.inputText = ""
        state.errorMessage = nil
        let userMessage = ChatMessage(id: uuid(), role: .user, content: prompt)
        state.messages.append(userMessage)
        state.artifact.updatedAt = date()

        let request = ChatRequest(
          model: state.model,
          messages: ChatContext.build(messages: Array(state.messages)),
          apiKey: apiKey
        )

        let assistantID = uuid()
        state.messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))
        state.streamingMessageID = assistantID
        state.isStreaming = true

        return .merge(
          persist { [artifact = state.artifact] database in
            try await database.saveMessage(message: userMessage, artifactID: artifact.id)
            try await database.updateArtifact(artifact)
          },
          .run { [openRouter] send in
            for try await delta in try await openRouter.streamChat(request) {
              await send(.streamDelta(delta))
            }
            await send(.streamFinished)
          } catch: { error, send in
            await send(.streamFailed(error.localizedDescription))
          }
          .cancellable(id: CancelID.stream, cancelInFlight: true)
        )

      case .streamDelta(let delta):
        guard let id = state.streamingMessageID else { return .none }
        state.messages[id: id]?.content += delta
        return .none

      case .streamFinished:
        state.isStreaming = false
        guard let id = state.streamingMessageID else { return .none }
        state.streamingMessageID = nil
        guard let message = state.messages[id: id], !message.content.isEmpty else {
          state.messages.remove(id: id)
          return .none
        }
        guard let html = HTMLExtractor.extract(from: message.content) else {
          // A plain chat turn (question answered, no app change): persist
          // the message but create no version.
          return persist { [artifactID = state.artifact.id] database in
            try await database.saveMessage(message: message, artifactID: artifactID)
          }
        }

        let version = ArtifactVersion(
          id: uuid(),
          artifactID: state.artifact.id,
          number: (state.versions.last?.number ?? 0) + 1,
          html: html,
          createdAt: date()
        )
        state.versions.append(version)
        if let title = HTMLExtractor.title(from: html) {
          state.artifact.title = title
        }
        state.artifact.updatedAt = date()
        state.tab = .preview
        return persist { [artifact = state.artifact] database in
          try await database.saveMessage(message: message, artifactID: artifact.id)
          try await database.createVersion(version)
          try await database.updateArtifact(artifact)
        }

      case .streamFailed(let message):
        state.isStreaming = false
        state.errorMessage = message
        return persistFinishedInFlightMessage(&state)

      case .cancelStreamTapped:
        guard state.isStreaming else { return .none }
        state.isStreaming = false
        return .merge(
          .cancel(id: CancelID.stream),
          persistFinishedInFlightMessage(&state)
        )

      case .historyButtonTapped:
        state.versionHistory = VersionHistoryFeature.State(
          versions: IdentifiedArray(uniqueElements: state.versions.reversed())
        )
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

  /// After a failure or cancellation: keep any partial text visible but
  /// marked failed (so it's excluded from future context) and persist it;
  /// drop the bubble entirely if nothing arrived.
  private func persistFinishedInFlightMessage(_ state: inout State) -> Effect<Action> {
    guard let id = state.streamingMessageID else { return .none }
    state.streamingMessageID = nil
    guard state.messages[id: id]?.content.isEmpty == false else {
      state.messages.remove(id: id)
      return .none
    }
    state.messages[id: id]?.isFailed = true
    guard let message = state.messages[id: id] else { return .none }
    return persist { [artifactID = state.artifact.id] database in
      try await database.saveMessage(message: message, artifactID: artifactID)
    }
  }
}
