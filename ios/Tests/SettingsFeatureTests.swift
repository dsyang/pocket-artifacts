import ComposableArchitecture
import XCTest

@testable import PocketArtifacts

@MainActor
final class SettingsFeatureTests: XCTestCase {
  static let curated = [
    OpenRouterModel(id: "anthropic/claude-sonnet-4.6", name: "Anthropic: Claude Sonnet 4.6")
  ]
  static let all = Self.curated + [
    OpenRouterModel(id: "tiny/chat-model", name: "Tiny: Chat Model")
  ]

  func testPickerLoadsCuratedProgrammingModelsByDefault() async {
    let requestedCategory = LockIsolated<String?>("unset")

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.listModels = { _, category in
        requestedCategory.setValue(category)
        return Self.curated
      }
    }

    await store.send(.modelListAppeared) {
      $0.isLoadingModels = true
    }
    await store.receive(.modelsLoaded(Self.curated)) {
      $0.isLoadingModels = false
      $0.models = Self.curated
    }
    XCTAssertEqual(requestedCategory.value, OpenRouterClient.programmingCategory)
  }

  func testShowAllModelsToggleRefetchesWithoutCategory() async {
    let requestedCategory = LockIsolated<String?>("unset")

    let store = TestStore(
      initialState: SettingsFeature.State(models: Self.curated)
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.keychainClient.apiKey = { "sk-or-test" }
      $0.openRouterClient.listModels = { _, category in
        requestedCategory.setValue(category)
        return Self.all
      }
    }

    await store.send(.binding(.set(\.showAllModels, true))) {
      $0.showAllModels = true
      $0.models = []
      $0.isLoadingModels = true
    }
    await store.receive(.modelsLoaded(Self.all)) {
      $0.isLoadingModels = false
      $0.models = Self.all
    }
    XCTAssertNil(requestedCategory.value)
  }

  func testSelectedModelStaysVisibleWhenNotInFetchedList() {
    let state = SettingsFeature.State(
      selectedModel: "anthropic/claude-sonnet-4.5",
      models: Self.curated
    )
    XCTAssertEqual(
      state.filteredModels.map(\.id),
      ["anthropic/claude-sonnet-4.5", "anthropic/claude-sonnet-4.6"]
    )
  }

  func testModelSelectionPersistsPreference() async {
    let saved = LockIsolated<String?>(nil)

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.modelPreference.setSelectedModel = { saved.setValue($0) }
    }

    await store.send(.modelSelected("openai/gpt-5.5")) {
      $0.selectedModel = "openai/gpt-5.5"
    }
    XCTAssertEqual(saved.value, "openai/gpt-5.5")
  }
}
