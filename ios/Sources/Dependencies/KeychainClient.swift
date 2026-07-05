import Dependencies
import DependenciesMacros
import Foundation
import Security

/// Minimal Keychain wrapper for the single secret we store: the user's
/// OpenRouter API key, as a generic password item.
@DependencyClient
struct KeychainClient: Sendable {
  var apiKey: @Sendable () -> String? = { nil }
  var setAPIKey: @Sendable (String) -> Void
  var deleteAPIKey: @Sendable () -> Void
}

extension KeychainClient: DependencyKey {
  private static let service = "fyi.imdaniel.pocketartifacts"
  private static let account = "openrouter-api-key"

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  static let liveValue = KeychainClient(
    apiKey: {
      var query = baseQuery
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      guard
        status == errSecSuccess,
        let data = result as? Data,
        let key = String(data: data, encoding: .utf8),
        !key.isEmpty
      else { return nil }
      return key
    },
    setAPIKey: { key in
      let data = Data(key.utf8)
      let updateStatus = SecItemUpdate(
        baseQuery as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
      if updateStatus == errSecItemNotFound {
        var query = baseQuery
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
      }
    },
    deleteAPIKey: {
      SecItemDelete(baseQuery as CFDictionary)
    }
  )

  static let testValue = KeychainClient()
}

extension DependencyValues {
  var keychainClient: KeychainClient {
    get { self[KeychainClient.self] }
    set { self[KeychainClient.self] = newValue }
  }
}
