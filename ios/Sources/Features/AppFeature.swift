import ComposableArchitecture
import SwiftUI

/// Root feature: hosts the editor and presents Settings — automatically on
/// first run (no API key yet) or when the editor reports a missing key.
@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var editor = EditorFeature.State()
    @Presents var settings: SettingsFeature.State?
  }

  enum Action {
    case onAppear
    case settingsButtonTapped
    case editor(EditorFeature.Action)
    case settings(PresentationAction<SettingsFeature.Action>)
  }

  @Dependency(\.keychainClient) var keychain

  var body: some ReducerOf<Self> {
    Scope(state: \.editor, action: \.editor) {
      EditorFeature()
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

      case .editor(.delegate(.apiKeyRequired)):
        state.settings = SettingsFeature.State()
        return .none

      case .editor:
        return .none

      case .settings:
        return .none
      }
    }
    .ifLet(\.$settings, action: \.settings) {
      SettingsFeature()
    }
  }
}

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    NavigationStack {
      EditorView(store: store.scope(state: \.editor, action: \.editor))
        .navigationTitle("Pocket Artifacts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              store.send(.settingsButtonTapped)
            } label: {
              Image(systemName: "gearshape")
            }
          }
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
