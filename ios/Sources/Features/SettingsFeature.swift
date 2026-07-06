import ComposableArchitecture
import Foundation
import SwiftUI

/// App-wide settings: just the OpenRouter API key. Model choice used to live
/// here as a single global preference; it's now per-chat (see
/// `ModelPickerFeature`, presented from the editor).
@Reducer
struct SettingsFeature {
  @ObservableState
  struct State: Equatable {
    var apiKeyInput = ""
    var hasExistingKey = false
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case onAppear
    case saveTapped
    case removeKeyTapped
    case doneTapped
  }

  @Dependency(\.keychainClient) var keychain
  @Dependency(\.dismiss) var dismiss

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .onAppear:
        state.hasExistingKey = keychain.apiKey() != nil
        return .none

      case .saveTapped:
        let key = state.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .none }
        keychain.setAPIKey(key)
        state.apiKeyInput = ""
        state.hasExistingKey = true
        return .run { _ in await dismiss() }

      case .removeKeyTapped:
        keychain.deleteAPIKey()
        state.hasExistingKey = false
        return .none

      case .doneTapped:
        return .run { _ in await dismiss() }
      }
    }
  }
}

struct SettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if store.hasExistingKey {
            Label("API key saved", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
            Button("Remove key", role: .destructive) {
              store.send(.removeKeyTapped)
            }
          }
          SecureField("sk-or-…", text: $store.apiKeyInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button("Save key") {
            store.send(.saveTapped)
          }
          .disabled(
            store.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        } header: {
          Text("OpenRouter API key")
        } footer: {
          Text(
            "Pocket Artifacts is bring-your-own-key: it talks to AI models through your OpenRouter account. Your key is stored in the iOS Keychain and never leaves this device except to call OpenRouter."
          )
        }

        Section {
          Link(
            "Get an API key at openrouter.ai/keys",
            destination: URL(string: "https://openrouter.ai/keys")!
          )
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            store.send(.doneTapped)
          }
        }
      }
    }
    .onAppear {
      store.send(.onAppear)
    }
  }
}
