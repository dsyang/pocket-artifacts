import ComposableArchitecture
import Foundation
import SwiftUI

/// Per-chat model picker. Presented from the editor with the chat's current
/// model; reports the new choice back to the editor via `delegate`, which
/// stores it on the artifact. Fed by GET /api/v1/models — OpenRouter's
/// curated "programming" category by default, the full catalog behind a
/// toggle.
@Reducer
struct ModelPickerFeature {
  @ObservableState
  struct State: Equatable {
    var selectedModel: String
    var models: [OpenRouterModel] = []
    var isLoadingModels = false
    var modelsError: String?
    var modelFilter = ""
    /// Off (default): OpenRouter's curated "programming" category — the
    /// short list of models that are actually good at building apps. On:
    /// the full catalog, for anyone who wants an off-list model.
    var showAllModels = false

    /// The rows to show, with the selected model pinned to the very top and
    /// everything else in the server's (name-sorted) order. The current
    /// choice stays visible (and re-selectable) even when it isn't in the
    /// fetched list — e.g. a model that has left the curated category since
    /// it was picked.
    var displayedModels: [OpenRouterModel] {
      var models = self.models
      if !models.contains(where: { $0.id == selectedModel }) {
        models.insert(OpenRouterModel(id: selectedModel, name: selectedModel), at: 0)
      }
      let matches = modelFilter.isEmpty
        ? models
        : models.filter {
          $0.id.localizedCaseInsensitiveContains(modelFilter)
            || $0.name.localizedCaseInsensitiveContains(modelFilter)
        }
      guard let index = matches.firstIndex(where: { $0.id == selectedModel }) else {
        return matches
      }
      var reordered = matches
      reordered.insert(reordered.remove(at: index), at: 0)
      return reordered
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case modelListAppeared
    case modelsLoaded([OpenRouterModel])
    case modelsFailed(String)
    case modelSelected(String)
    case doneTapped
    case delegate(Delegate)

    enum Delegate: Equatable {
      /// The user picked a model; the parent persists it on the artifact.
      case modelSelected(String)
    }
  }

  @Dependency(\.keychainClient) var keychain
  @Dependency(\.openRouterClient) var openRouter
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
        return .send(.delegate(.modelSelected(id)))

      case .doneTapped:
        return .run { _ in await dismiss() }

      case .delegate:
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

/// Searchable model list. The selected model sits at the top and is the only
/// row rendered in the tint (blue) colour; tapping any row selects it.
struct ModelPickerView: View {
  @Bindable var store: StoreOf<ModelPickerFeature>

  var body: some View {
    NavigationStack {
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
            ForEach(store.displayedModels) { model in
              let isSelected = model.id == store.selectedModel
              Button {
                store.send(.modelSelected(model.id))
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                      .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    Text(model.id)
                      .font(.system(.footnote, design: .monospaced))
                      .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                  }
                  Spacer()
                  if isSelected {
                    Image(systemName: "checkmark")
                      .foregroundStyle(Color.accentColor)
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
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            store.send(.doneTapped)
          }
        }
      }
      .onAppear {
        store.send(.modelListAppeared)
      }
    }
  }
}
