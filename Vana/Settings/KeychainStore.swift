import Foundation
import Security

enum KeychainStore {
    static let apiKeyAccount = "aikit-api-key"
    /// 网页搜索(serper.dev)的 key。和模型的那把分开存:它们来自两个服务、两次注册,
    /// 换掉其中一把不该动到另一把。
    static let searchAPIKeyAccount = "serper-api-key"

    private static let service = "com.pinapia.vana.ios"

    static func get(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    static func set(_ value: String, account: String) throws {
        try delete(account: account)

        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private enum KeychainError: LocalizedError {
    case invalidData
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "钥匙串中的 API key 无法读取"
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return message ?? "钥匙串操作失败（\(status)）"
        }
    }
}
