import ComposableArchitecture
import XCTest

@testable import PocketArtifacts

@MainActor
final class ModelPickerFeatureTests: XCTestCase {
  static let curated = [
    OpenRouterModel(id: "anthropic/claude-sonnet-4.6", name: "Anthropic: Claude Sonnet 4.6")
  ]
  static let all = curated + [
    OpenRouterModel(id: "tiny/chat-model", name: "Tiny: Chat Model")
  ]

  func testPickerLoadsCuratedProgrammingModelsByDefault() async {
    let requestedCategory = LockIsolated<String?>("unset")

    let store = TestStore(
      initialState: ModelPickerFeature.State(selectedModel: OpenRouterClient.defaultModel)
    ) {
      ModelPickerFeature()
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
      initialState: ModelPickerFeature.State(
        selectedModel: OpenRouterClient.defaultModel, models: Self.curated
      )
    ) {
      ModelPickerFeature()
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
    let state = ModelPickerFeature.State(
      selectedModel: "anthropic/claude-sonnet-4.5",
      models: Self.curated
    )
    // The off-list selection is injected and, being selected, sits on top.
    XCTAssertEqual(
      state.displayedModels.map(\.id),
      ["anthropic/claude-sonnet-4.5", "anthropic/claude-sonnet-4.6"]
    )
  }

  func testSelectedModelIsPinnedToTop() {
    // Selected model sorts last by name but must still surface at the top.
    let state = ModelPickerFeature.State(
      selectedModel: "tiny/chat-model",
      models: Self.all
    )
    XCTAssertEqual(
      state.displayedModels.map(\.id),
      ["tiny/chat-model", "anthropic/claude-sonnet-4.6"]
    )
  }

  func testFilterKeepsMatchesAndStillPinsSelected() {
    let state = ModelPickerFeature.State(
      selectedModel: "tiny/chat-model",
      models: Self.all,
      modelFilter: "model"
    )
    // Both ids contain "model"; the selected one is still first.
    XCTAssertEqual(
      state.displayedModels.map(\.id),
      ["tiny/chat-model", "anthropic/claude-sonnet-4.6"]
    )
  }

  func testModelSelectionEmitsDelegate() async {
    let store = TestStore(
      initialState: ModelPickerFeature.State(selectedModel: OpenRouterClient.defaultModel)
    ) {
      ModelPickerFeature()
    }

    await store.send(.modelSelected("openai/gpt-5.5")) {
      $0.selectedModel = "openai/gpt-5.5"
    }
    await store.receive(.delegate(.modelSelected("openai/gpt-5.5")))
  }
}
