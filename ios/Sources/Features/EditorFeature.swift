import ComposableArchitecture
import Foundation

/// The chat-driven editor: send a prompt, stream the response into an
/// in-flight assistant bubble, extract the HTML fence when the stream
/// finishes, and flip to the preview tab with the new version.
@Reducer
struct EditorFeature {
  @ObservableState
  struct State: Equatable {
    var messages: IdentifiedArrayOf<ChatMessage> = []
    var inputText = ""
    var isStreaming = false
    /// ID of the assistant message currently receiving stream deltas.
    var streamingMessageID: UUID?
    /// The latest extracted artifact HTML, shown in Preview and Code tabs.
    var currentHTML: String?
    /// Bumped on every new version so the WKWebView knows to reload.
    var htmlVersion = 0
    var tab = Tab.chat
    var errorMessage: String?
    var model = OpenRouterClient.defaultModel

    enum Tab: String, Equatable, CaseIterable {
      case chat = "Chat"
      case preview = "Preview"
      case code = "Code"
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case sendTapped
    case cancelStreamTapped
    case streamDelta(String)
    case streamFinished
    case streamFailed(String)
    case delegate(Delegate)

    enum Delegate: Equatable {
      case apiKeyRequired
    }
  }

  @Dependency(\.openRouterClient) var openRouter
  @Dependency(\.keychainClient) var keychain
  @Dependency(\.uuid) var uuid

  private enum CancelID {
    case stream
  }

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .sendTapped:
        let prompt = state.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !state.isStreaming else { return .none }
        guard let apiKey = keychain.apiKey() else {
          return .send(.delegate(.apiKeyRequired))
        }

        state.inputText = ""
        state.errorMessage = nil
        state.messages.append(ChatMessage(id: uuid(), role: .user, content: prompt))

        let request = ChatRequest(
          model: state.model,
          messages: ChatContext.build(messages: Array(state.messages)),
          apiKey: apiKey
        )

        let assistantID = uuid()
        state.messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))
        state.streamingMessageID = assistantID
        state.isStreaming = true

        return .run { [openRouter] send in
          for try await delta in try await openRouter.streamChat(request) {
            await send(.streamDelta(delta))
          }
          await send(.streamFinished)
        } catch: { error, send in
          await send(.streamFailed(error.localizedDescription))
        }
        .cancellable(id: CancelID.stream, cancelInFlight: true)

      case .streamDelta(let delta):
        guard let id = state.streamingMessageID else { return .none }
        state.messages[id: id]?.content += delta
        return .none

      case .streamFinished:
        state.isStreaming = false
        guard let id = state.streamingMessageID else { return .none }
        state.streamingMessageID = nil
        let content = state.messages[id: id]?.content ?? ""
        if content.isEmpty {
          state.messages.remove(id: id)
        } else if let html = HTMLExtractor.extract(from: content) {
          state.currentHTML = html
          state.htmlVersion += 1
          state.tab = .preview
        }
        return .none

      case .streamFailed(let message):
        state.isStreaming = false
        state.errorMessage = message
        finishInFlightMessage(&state)
        return .none

      case .cancelStreamTapped:
        guard state.isStreaming else { return .none }
        state.isStreaming = false
        finishInFlightMessage(&state)
        return .cancel(id: CancelID.stream)

      case .delegate:
        return .none
      }
    }
  }

  /// After a failure or cancellation: keep any partial text visible but
  /// marked failed (so it's excluded from future context); drop the bubble
  /// entirely if nothing arrived.
  private func finishInFlightMessage(_ state: inout State) {
    guard let id = state.streamingMessageID else { return }
    state.streamingMessageID = nil
    if state.messages[id: id]?.content.isEmpty == true {
      state.messages.remove(id: id)
    } else {
      state.messages[id: id]?.isFailed = true
    }
  }
}
