import ComposableArchitecture
import SwiftUI

@main
struct PocketArtifactsApp: App {
  static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: Self.store)
    }
  }
}
