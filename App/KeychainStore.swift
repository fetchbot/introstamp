import Foundation
import LocalAuthentication
import Security

struct KeychainStore {
    enum Key: String {
        case theIntroDBAPIKey = "theintrodb_api_key"
        case introDBAPIKey = "introdb_api_key"
        case tmdbAPIKey = "tmdb_api_key"
    }

    private let service: String

    init(service: String = "IntroStamp") {
        self.service = service
    }

    func get(_ key: Key, allowUserInteraction: Bool = true) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = !allowUserInteraction

      let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    @discardableResult
    func set(_ value: String, for key: Key) -> Bool {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }

        return false
    }
}
