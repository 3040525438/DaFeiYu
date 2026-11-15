import XCTest
import GRDB
import DFCore
@testable import DFData

/// D72：备份写入本机标识，跨设备恢复必须用户确认，结构版本不一致拒绝恢复。
final class BackupDeviceOriginTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var keyStore: KeyStoreStub!

    private let key = Data((0..<32).map { UInt8($0) })
    private let timestamp: Int64 = 2_000_000

    /// 测试用替身：XOR 流 + 标签（生产为 AES-GCM）
    private struct TestCipher: BackupCipher {
        let identifier = "test-xor"

        func seal(_ plaintext: Data, key: Data, nonce: Data) throws -> Data {
            try BackupContainer.validateKey(key)
            let stream = [UInt8](key + nonce)
            var output = Data()
            for (index, byte) in plaintext.enumerated() {
                output.append(byte ^ stream[index % stream.count])
            }
            output.append(contentsOf: Array(SHA256.hash(key + nonce + plaintext).utf8.prefix(16)))
            return output
        }

        func open(_ sealed: Data, key: Data, nonce: Data) throws -> Data {
            try BackupContainer.validateKey(key)
            guard sealed.count > 16 else { throw BackupCipherError.truncatedContainer }
            let stream = [UInt8](key + nonce)
            var output = Data()
            for (index, byte) in sealed.prefix(sealed.count - 16).enumerated() {
                output.append(byte ^ stream[index % stream.count])
            }
            let expected = Array(SHA256.hash(key + nonce + output).utf8.prefix(16))
            guard [UInt8](sealed.suffix(16)) == expected else {
                throw BackupCipherError.authenticationFailed
            }
            return output
        }
    }

    private final class KeyStoreStub: BackupKeyStoring, @unchecked Sendable {
        private var key: Data?
        init(key: Data?) { self.key = key }
        func loadOrCreateKey() throws -> Data {
            if let key { return key }
            let created = Data(repeating: 7, count: 32)
            key = created
            return created
        }
        func existingKey() throws -> Data? { key }
        func deleteKey() throws { key = nil }
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFRestoreOrigin-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        keyStore = KeyStoreStub(key: key)
        try await seed()
    }

    override func tearDownWithError() throws {
        database = nil
        keyStore = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func seed() async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT OR IGNORE INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '主会话', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'u1', 'c1', 'user', 'text', '你好', 'sent', 'local', 1)
            """)
        }
    }

    private func makeService() -> BackupService {
        BackupService(
            database: database,
            keyStore: keyStore,
            cipher: TestCipher(),
            appVersion: "0.1.0",
            now: { self.timestamp }
        )
    }

    private func setInstallID(_ value: String) async throws {
        try await GRDBSettingsRepository(database: database).set(value, for: BackupService.deviceIDKey)
    }

    // MARK: - 备份写入设备标识

    func testBackupRecordsInstallID() async throws {
        let service = makeService()
        let installID = await service.deviceID()
        XCTAssertNotNil(installID)

        let manifest = try await service.createBackup(kind: .manual)
        let snapshot = try await service.readSnapshot(manifestID: manifest.id)
        XCTAssertEqual(snapshot.sourceDeviceID, installID)

        // 再次调用必须复用同一个 id
        let again = await service.deviceID()
        XCTAssertEqual(again, installID)
    }

    func testInstallIDIsStableWhenPreset() async throws {
        try await setInstallID("device-fixed")
        let service = makeService()
        let id = await service.deviceID()
        XCTAssertEqual(id, "device-fixed")
    }

    // MARK: - 跨设备恢复

    func testSameDeviceRestoreSucceedsWithoutConfirmation() async throws {
        let service = makeService()
        let manifest = try await service.createBackup(kind: .manual)
        let log = try await service.restore(manifestID: manifest.id)
        XCTAssertEqual(log.status, "completed")
    }

    func testOtherDeviceRestoreRequiresConfirmation() async throws {
        let service = makeService()
        let manifest = try await service.createBackup(kind: .manual)

        // 模拟换机：本机安装标识变为另一台设备
        try await setInstallID("device-other")

        do {
            _ = try await service.restore(manifestID: manifest.id)
            XCTFail("跨设备恢复必须要求确认")
        } catch let error as BackupService.RestoreGuardError {
            guard case .confirmationRequired(let reason) = error else {
                return XCTFail("应为 confirmationRequired，实际 \(error)")
            }
            XCTAssertTrue(reason.contains("整体替换"))
            XCTAssertTrue(reason.contains("不会自动合并"))
        }

        // 未确认时不得创建保护备份，也不得写恢复日志
        let safety = try await GRDBBackupRepository(database: database).manifests(kind: .safety, limit: 10)
        XCTAssertTrue(safety.isEmpty)
        let logs = try await GRDBBackupRepository(database: database).restoreLogs(limit: 10)
        XCTAssertTrue(logs.isEmpty)
    }

    func testConfirmedCrossDeviceRestoreSucceeds() async throws {
        let service = makeService()
        let manifest = try await service.createBackup(kind: .manual)
        try await setInstallID("device-other")

        let log = try await service.restore(manifestID: manifest.id, confirmedCrossDevice: true)
        XCTAssertEqual(log.status, "completed")
        XCTAssertNotNil(log.safetyBackupID, "恢复前必须留下保护备份")
    }

    // MARK: - 结构版本不一致

    func testSchemaMismatchIsBlocked() async throws {
        let service = makeService()
        let manifest = try await service.createBackup(kind: .manual)

        // 把快照里的结构版本改写成另一个版本，模拟不同结构的备份
        var snapshot = try await service.readSnapshot(manifestID: manifest.id)
        snapshot.schemaVersion = "v99_future"
        let plaintext = try JSONEncoder().encode(snapshot)
        let sealed = try BackupContainer.seal(plaintext, key: key, cipher: TestCipher())
        try sealed.write(to: service.fileURL(for: manifest), options: .atomic)

        // previewRestore 会先行拒绝，这里直接验证 restore 的兜底门禁同样生效
        do {
            _ = try await service.restore(manifestID: manifest.id, confirmedCrossDevice: true)
            XCTFail("结构不一致应拒绝恢复")
        } catch let error as BackupError {
            XCTAssertEqual(error, .incompatibleSchema("v99_future"))
        }
    }
}
