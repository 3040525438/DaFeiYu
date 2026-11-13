import Foundation
import DFCore

#if canImport(Security)
import Security

/// Keychain 封装。仅在 Apple 平台可用。
/// - 使用 AfterFirstUnlockThisDeviceOnly：后台任务可读，且不随 iCloud 迁移到其他设备。
/// - 每个环境（正式版/实验版）使用不同的 service，密钥互不可见。
public struct KeychainStore: SecureStore, Sendable {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    public func set(_ value: String, for key: String) throws {
        var query = baseQuery(key)
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DFError.database("Keychain 写入失败（状态码 \(status)）")
        }
    }

    public func get(_ key: String) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DFError.database("Keychain 读取失败（状态码 \(status)）")
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DFError.database("Keychain 删除失败（状态码 \(status)）")
        }
    }
}

#else

/// 非 Apple 平台没有 Keychain。这里显式抛错，
/// 避免出现"看起来保存成功、实际明文落盘"的假安全实现。
public struct KeychainStore: SecureStore, Sendable {
    public init(service: String) {}

    public func set(_ value: String, for key: String) throws {
        throw DFError.unsupported("Keychain 仅支持 Apple 平台")
    }

    public func get(_ key: String) throws -> String? {
        throw DFError.unsupported("Keychain 仅支持 Apple 平台")
    }

    public func delete(_ key: String) throws {
        throw DFError.unsupported("Keychain 仅支持 Apple 平台")
    }
}

#endif
