import ComposableArchitecture
import SwiftUI

/// Root feature: the library at the root of a navigation stack, editors
/// pushed on top, and Settings as a sheet — presented automatically on
/// first run (no API key yet) or when the editor reports a missing key.
@Reducer
struct AppFeature {
  @Reducer
  enum Path {
    case editor(EditorFeature)
  }

  @ObservableState
  struct State: Equatable {
    var library = LibraryFeature.State()
    var path = StackState<Path.State>()
    @Presents var settings: SettingsFeature.State?
  }

  enum Action {
    case onAppear
    case settingsButtonTapped
    case library(LibraryFeature.Action)
    case path(StackActionOf<Path>)
    case settings(PresentationAction<SettingsFeature.Action>)
  }

  @Dependency(\.keychainClient) var keychain

  var body: some ReducerOf<Self> {
    Scope(state: \.library, action: \.library) {
      LibraryFeature()
    }
    Reduce { state, action in
      switch action {
      case .onAppear:
        if keychain.apiKey() == nil {
          state.settings = SettingsFeature.State()
        }
        return .none

      case .settingsButtonTapped:
        state.settings = SettingsFeature.State()
        return .none

      case .library(.delegate(.openArtifact(let artifact))):
        state.path.append(.editor(EditorFeature.State(artifact: artifact)))
        return .none

      case .library:
        return .none

      case .path(.element(id: _, action: .editor(.delegate(.apiKeyRequired)))):
        state.settings = SettingsFeature.State()
        return .none

      case .path(.popFrom):
        // The editor may have renamed or touched the artifact; reload the
        // list so titles and ordering are fresh.
        return .send(.library(.refresh))

      case .path:
        return .none

      case .settings:
        return .none
      }
    }
    .forEach(\.path, action: \.path)
    .ifLet(\.$settings, action: \.settings) {
      SettingsFeature()
    }
  }
}

extension AppFeature.Path.State: Equatable {}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
      LibraryView(store: store.scope(state: \.library, action: \.library))
        .navigationTitle("Pocket Artifacts")
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              store.send(.settingsButtonTapped)
            } label: {
              Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
          }
        }
    } destination: { store in
      switch store.case {
      case .editor(let editorStore):
        EditorView(store: editorStore)
      }
    }
    .onAppear {
      store.send(.onAppear)
    }
    .sheet(item: $store.scope(state: \.settings, action: \.settings)) { settingsStore in
      SettingsView(store: settingsStore)
    }
  }
}
