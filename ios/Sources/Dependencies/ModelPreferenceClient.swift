import Dependencies
import Foundation

/// Remembers the user's model choice across launches (UserDefaults — it's a
/// preference, not a secret). Deliberately not @DependencyClient: reading a
/// preference is benign, so the test value quietly returns "no choice yet"
/// instead of failing tests that don't care about it.
struct ModelPreferenceClient: Sendable {
  var selectedModel: @Sendable () -> String?
  var setSelectedModel: @Sendable (String) -> Void
}

extension ModelPreferenceClient: DependencyKey {
  private static let key = "selectedModel"

  static let liveValue = ModelPreferenceClient(
    selectedModel: { UserDefaults.standard.string(forKey: key) },
    setSelectedModel: { UserDefaults.standard.set($0, forKey: key) }
  )

  static let testValue = ModelPreferenceClient(
    selectedModel: { nil },
    setSelectedModel: { _ in }
  )
}

extension DependencyValues {
  var modelPreference: ModelPreferenceClient {
    get { self[ModelPreferenceClient.self] }
    set { self[ModelPreferenceClient.self] = newValue }
  }
}
