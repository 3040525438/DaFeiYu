import Foundation
import DFCore
import DFAI

/// 备份主密钥（D44）：32 字节随机数，Base64 存系统 Keychain。
/// 密钥**不会**写入数据库、不会随备份导出；删除密钥后既有备份永久不可解密。
struct KeychainBackupKeyStore: BackupKeyStoring {
    let store: KeychainStore
    var keyRef: String = "backup.master.key.v1"

    func loadOrCreateKey() throws -> Data {
        if let existing = try existingKey() { return existing }
        var generator = SystemRandomNumberGenerator()
        let created = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try store.set(created.base64EncodedString(), for: keyRef)
        return created
    }

    func existingKey() throws -> Data? {
        guard let text = try store.get(keyRef),
              let data = Data(base64Encoded: text),
              data.count == 32 else {
            return nil
        }
        return data
    }

    func deleteKey() throws {
        try store.delete(keyRef)
    }
}
