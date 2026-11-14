#if canImport(CryptoKit)
import Foundation
import CryptoKit

/// 真机 / macOS 上的默认实现：AES-256-GCM。
/// Linux CI 无 CryptoKit，改用测试替身验证容器与流程（算法本身需真机验收）。
public struct CryptoKitBackupCipher: BackupCipher {
    public let identifier = "aes-256-gcm"

    public init() {}

    public func seal(_ plaintext: Data, key: Data, nonce: Data) throws -> Data {
        try BackupContainer.validateKey(key)
        guard nonce.count == BackupContainer.nonceLength else {
            throw BackupCipherError.truncatedContainer
        }
        let box = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: try AES.GCM.Nonce(data: nonce)
        )
        return box.ciphertext + box.tag
    }

    public func open(_ sealed: Data, key: Data, nonce: Data) throws -> Data {
        try BackupContainer.validateKey(key)
        guard sealed.count > 16 else { throw BackupCipherError.truncatedContainer }
        let ciphertext = sealed.prefix(sealed.count - 16)
        let tag = sealed.suffix(16)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw BackupCipherError.authenticationFailed
        }
    }
}
#endif
