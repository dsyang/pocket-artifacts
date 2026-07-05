import ComposableArchitecture
import Foundation
import SwiftUI

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State: Equatable {
    var apiKeyInput = ""
    var hasExistingKey = false
    var selectedModel = OpenRouterClient.defaultModel
    var models: [OpenRouterModel] = []
    var isLoadingModels = false
    var modelsError: String?
    var modelFilter = ""
    /// Off (default): OpenRouter's curated "programming" category — the
    /// short list of models that are actually good at building apps. On:
    /// the full catalog, for anyone who wants an off-list model.
    var showAllModels = false

    var filteredModels: [OpenRouterModel] {
      var models = self.models
      // The current choice stays visible (and re-selectable) even when it
      // isn't in the fetched list — e.g. a model that has left the curated
      // category since it was picked.
      if !models.isEmpty, !models.contains(where: { $0.id == selectedModel }) {
        models.insert(OpenRouterModel(id: selectedModel, name: selectedModel), at: 0)
      }
      guard !modelFilter.isEmpty else { return models }
      return models.filter {
        $0.id.localizedCaseInsensitiveContains(modelFilter)
          || $0.name.localizedCaseInsensitiveContains(modelFilter)
      }
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case onAppear
    case saveTapped
    case removeKeyTapped
    case doneTapped
    case modelListAppeared
    case modelsLoaded([OpenRouterModel])
    case modelsFailed(String)
    case modelSelected(String)
  }

  @Dependency(\.keychainClient) var keychain
  @Dependency(\.openRouterClient) var openRouter
  @Dependency(\.modelPreference) var modelPreference
  @Dependency(\.dismiss) var dismiss

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.showAllModels):
        state.models = []
        return fetchModels(&state)

      case .binding:
        return .none

      case .onAppear:
        state.hasExistingKey = keychain.apiKey() != nil
        state.selectedModel = modelPreference.selectedModel() ?? OpenRouterClient.defaultModel
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

      case .modelListAppeared:
        guard state.models.isEmpty, !state.isLoadingModels else { return .none }
        return fetchModels(&state)

      case .modelsLoaded(let models):
        state.isLoadingModels = false
        state.models = models
        return .none

      case .modelsFailed(let message):
        state.isLoadingModels = false
        state.modelsError = message
        return .none

      case .modelSelected(let id):
        state.selectedModel = id
        modelPreference.setSelectedModel(id)
        return .none
      }
    }
  }

  private func fetchModels(_ state: inout State) -> Effect<Action> {
    state.isLoadingModels = true
    state.modelsError = nil
    let category = state.showAllModels ? nil : OpenRouterClient.programmingCategory
    return .run { send in
      try await send(
        .modelsLoaded(openRouter.listModels(apiKey: keychain.apiKey(), category: category))
      )
    } catch: { error, send in
      await send(.modelsFailed(error.localizedDescription))
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

        Section("Model") {
          NavigationLink {
            ModelPickerView(store: store)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text("Model")
              Text(store.selectedModel)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
            }
          }
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

/// Searchable model list fed by GET /api/v1/models — OpenRouter's curated
/// "programming" category by default, the full catalog behind a toggle.
/// The current choice is checked; tapping a row selects it (persisted via
/// ModelPreference).
struct ModelPickerView: View {
  @Bindable var store: StoreOf<SettingsFeature>

  var body: some View {
    List {
      Section {
        Toggle("Show all models", isOn: $store.showAllModels)
      } footer: {
        Text(
          store.showAllModels
            ? "Every model on OpenRouter — most aren't good at building apps."
            : "OpenRouter's curated list of models that are best at programming."
        )
      }

      Section {
        if store.isLoadingModels {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
        } else if let error = store.modelsError {
          VStack(alignment: .leading, spacing: 8) {
            Text(error)
              .font(.footnote)
              .foregroundStyle(.secondary)
            Button("Retry") {
              store.send(.modelListAppeared)
            }
          }
        } else {
          ForEach(store.filteredModels) { model in
            Button {
              store.send(.modelSelected(model.id))
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(model.name)
                    .foregroundStyle(.primary)
                  Text(model.id)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if model.id == store.selectedModel {
                  Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                }
              }
            }
          }
        }
      }
    }
    .searchable(
      text: $store.modelFilter,
      placement: .navigationBarDrawer(displayMode: .always),
      prompt: "Search models"
    )
    .navigationTitle("Model")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      store.send(.modelListAppeared)
    }
  }
}
