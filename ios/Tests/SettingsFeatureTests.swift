import ComposableArchitecture
import XCTest

@testable import PocketArtifacts

@MainActor
final class SettingsFeatureTests: XCTestCase {
  func testOnAppearReflectsExistingKey() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.keychainClient.apiKey = { "sk-or-existing" }
    }

    await store.send(.onAppear) {
      $0.hasExistingKey = true
    }
  }

  func testSaveStoresKeyAndDismisses() async {
    let saved = LockIsolated<String?>(nil)

    let store = TestStore(
      initialState: SettingsFeature.State(apiKeyInput: "  sk-or-new  ")
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.keychainClient.setAPIKey = { saved.setValue($0) }
      $0.dismiss = DismissEffect {}
    }

    await store.send(.saveTapped) {
      // Trimmed, stored, and the input cleared.
      $0.apiKeyInput = ""
      $0.hasExistingKey = true
    }
    XCTAssertEqual(saved.value, "sk-or-new")
  }

  func testRemoveKeyClearsExistingFlag() async {
    let deleted = LockIsolated(false)

    let store = TestStore(
      initialState: SettingsFeature.State(hasExistingKey: true)
    ) {
      SettingsFeature()
    } withDependencies: {
      $0.keychainClient.deleteAPIKey = { deleted.setValue(true) }
    }

    await store.send(.removeKeyTapped) {
      $0.hasExistingKey = false
    }
    XCTAssertTrue(deleted.value)
  }
}
