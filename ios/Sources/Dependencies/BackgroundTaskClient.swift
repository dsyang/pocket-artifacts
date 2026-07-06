import Dependencies
import DependenciesMacros
import UIKit

/// TCA dependency wrapping UIApplication's finite background-task API so
/// `GenerationService` can ask iOS for the ~30s grace window while a stream
/// is in flight, without touching UIKit (or the main actor) directly. Tests
/// swap in a mock to assert the begin/end pairing and drive expiration.
@DependencyClient
struct BackgroundTaskClient: Sendable {
  /// Begins a finite-length background task; returns `.invalid` when iOS
  /// declines. `onExpiration` fires just before iOS reclaims the window —
  /// the live value ends the task itself after invoking it, per UIKit's
  /// contract, so callers only need to `end` on their own completion.
  var begin: @Sendable (_ name: String, _ onExpiration: @escaping @Sendable () -> Void)
    async -> UIBackgroundTaskIdentifier = { _, _ in .invalid }
  var end: @Sendable (_ id: UIBackgroundTaskIdentifier) async -> Void
}

extension BackgroundTaskClient: DependencyKey {
  static let liveValue = BackgroundTaskClient(
    begin: { name, onExpiration in
      await MainActor.run {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
          onExpiration()
          UIApplication.shared.endBackgroundTask(id)
        }
        return id
      }
    },
    end: { id in
      guard id != .invalid else { return }
      await MainActor.run { UIApplication.shared.endBackgroundTask(id) }
    }
  )

  static let testValue = BackgroundTaskClient()
}

extension DependencyValues {
  var backgroundTaskClient: BackgroundTaskClient {
    get { self[BackgroundTaskClient.self] }
    set { self[BackgroundTaskClient.self] = newValue }
  }
}
