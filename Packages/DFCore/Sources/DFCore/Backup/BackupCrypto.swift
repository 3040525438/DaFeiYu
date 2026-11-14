import Foundation

// MARK: - 备份加解密（W9 / D20、D44）

public enum BackupCipherError: Error, Equatable, CustomStringConvertible {
    case invalidKeyLength(Int)
    case badMagic
    case unsupportedVersion(UInt8)
    case truncatedContainer
    case authenticationFailed
    case cryptoUnavailable

    public var description: String {
        switch self {
        case .invalidKeyLength(let length): return "密钥长度非法：\(length) 字节（需要 32 字节）"
        case .badMagic: return "不是大肥鱼备份文件"
        case .unsupportedVersion(let version): return "备份容器版本不支持：\(version)"
        case .truncatedContainer: return "备份文件被截断"
        case .authenticationFailed: return "备份校验失败：密钥不对或文件已被篡改"
        case .cryptoUnavailable: return "当前平台没有可用的加密实现"
        }
    }
}

/// 对称认证加密抽象：实现负责"密文 + 认证标签"。
/// - CryptoKit 实现见 `CryptoKitBackupCipher`
/// - Linux / 单元测试用替身（真实算法出口必须在真机验证）
public protocol BackupCipher: Sendable {
    var identifier: String { get }
    func seal(_ plaintext: Data, key: Data, nonce: Data) throws -> Data
    func open(_ sealed: Data, key: Data, nonce: Data) throws -> Data
}

public enum BackupCipherFactory {
    /// 默认算法标识（写入 `backup_manifests.encryption_hint`）
    public static var defaultIdentifier: String {
        #if canImport(CryptoKit)
        return "aes-256-gcm"
        #else
        return "unavailable"
        #endif
    }

    public static func makeDefault() -> BackupCipher? {
        #if canImport(CryptoKit)
        return CryptoKitBackupCipher()
        #else
        return nil
        #endif
    }
}

/// 备份容器：`DFBK1` + 版本 + 12 字节 nonce + 密文（含认证标签）。
/// 明文备份**不经过**本容器，由上层显式二次确认后直接写 JSON。
public enum BackupContainer {
    public static let magic: [UInt8] = Array("DFBK1".utf8)
    public static let version: UInt8 = 1
    public static let nonceLength = 12
    public static var headerLength: Int { magic.count + 1 + nonceLength }

    public static func seal(
        _ plaintext: Data,
        key: Data,
        cipher: BackupCipher,
        nonce: Data? = nil
    ) throws -> Data {
        try validateKey(key)
        let actualNonce = nonce ?? randomNonce()
        guard actualNonce.count == nonceLength else { throw BackupCipherError.truncatedContainer }
        let sealed = try cipher.seal(plaintext, key: key, nonce: actualNonce)
        var container = Data(magic)
        container.append(version)
        container.append(actualNonce)
        container.append(sealed)
        return container
    }

    public static func open(_ container: Data, key: Data, cipher: BackupCipher) throws -> Data {
        try validateKey(key)
        guard container.count >= headerLength else { throw BackupCipherError.truncatedContainer }
        let bytes = [UInt8](container)
        guard Array(bytes[0..<magic.count]) == magic else { throw BackupCipherError.badMagic }
        let containerVersion = bytes[magic.count]
        guard containerVersion == version else { throw BackupCipherError.unsupportedVersion(containerVersion) }
        let nonce = Data(bytes[(magic.count + 1)..<headerLength])
        let sealed = Data(bytes[headerLength...])
        guard !sealed.isEmpty else { throw BackupCipherError.truncatedContainer }
        return try cipher.open(sealed, key: key, nonce: nonce)
    }

    public static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<nonceLength).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    public static func validateKey(_ key: Data) throws {
        guard key.count == 32 else { throw BackupCipherError.invalidKeyLength(key.count) }
    }
}

/// 备份密钥存储。App 层用 Keychain 实现；测试用内存替身。
/// 密钥**永不**随备份文件一起导出（D44：密钥丢失即无法解密）。
public protocol BackupKeyStoring: Sendable {
    /// 读取密钥；不存在则生成 32 字节随机密钥并持久化
    func loadOrCreateKey() throws -> Data
    func existingKey() throws -> Data?
    func deleteKey() throws
}

// MARK: - 备份快照（逻辑导出，不含引擎内部表）

public enum BackupValue: Codable, Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    /// base64（BLOB）
    case blob(String)
}

public struct BackupTableSnapshot: Codable, Sendable, Equatable {
    public var name: String
    public var columns: [String]
    public var rows: [[BackupValue]]

    public init(name: String, columns: [String], rows: [[BackupValue]]) {
        self.name = name
        self.columns = columns
        self.rows = rows
    }
}

public struct BackupSnapshot: Codable, Sendable, Equatable {
    public static let currentFormat = 1

    public var format: Int
    public var schemaVersion: String
    public var appVersion: String
    public var createdAt: Int64
    public var tables: [BackupTableSnapshot]
    /// 表名 → 行数（恢复预览与完整性核对）
    public var counts: [String: Int]

    public init(
        format: Int = BackupSnapshot.currentFormat,
        schemaVersion: String,
        appVersion: String,
        createdAt: Int64,
        tables: [BackupTableSnapshot],
        counts: [String: Int]
    ) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.tables = tables
        self.counts = counts
    }

    public var totalRows: Int { counts.values.reduce(0, +) }
}

public enum BackupSnapshotError: Error, Equatable, CustomStringConvertible {
    case unsupportedFormat(Int)
    case unknownTable(String)
    case columnMismatch(table: String)
    case rowWidthMismatch(table: String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let format): return "备份快照格式不支持：\(format)"
        case .unknownTable(let name): return "备份包含未知表：\(name)"
        case .columnMismatch(let table): return "恢复表结构不匹配：\(table)"
        case .rowWidthMismatch(let table): return "恢复行宽与列数不一致：\(table)"
        }
    }
}
