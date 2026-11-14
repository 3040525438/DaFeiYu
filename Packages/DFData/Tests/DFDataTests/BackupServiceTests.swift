import XCTest
import GRDB
import DFCore
@testable import DFData

/// W9：备份创建 / 校验 / 解密读取 / 恢复落地与失败不破坏
final class BackupServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var repo: GRDBBackupRepository!
    private var keyStore: MemoryKeyStore!
    private let now: Int64 = 1_000_000

    private let key = Data((0..<32).map { UInt8($0) })

    /// 测试用替身：XOR 流 + SHA256 截断标签（生产为 AES-GCM）
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

    private final class MemoryKeyStore: BackupKeyStoring, @unchecked Sendable {
        private var key: Data?
        init(key: Data?) { self.key = key }
        func loadOrCreateKey() throws -> Data {
            if let key { return key }
            let created = Data(repeating: 3, count: 32)
            key = created
            return created
        }
        func existingKey() throws -> Data? { key }
        func deleteKey() throws { key = nil }
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFBackup-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        repo = GRDBBackupRepository(database: database)
        keyStore = MemoryKeyStore(key: key)
    }

    override func tearDownWithError() throws {
        repo = nil
        database = nil
        keyStore = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeService(store: BackupKeyStoring? = nil) -> BackupService {
        let resolved: BackupKeyStoring = store ?? keyStore
        return BackupService(
            database: database,
            keyStore: resolved,
            cipher: TestCipher(),
            appVersion: "0.1.0",
            now: { self.now }
        )
    }

    private func seedConversationAndMessage(_ suffix: String = "") async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT OR IGNORE INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '主会话', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES (?, ?, 'c1', 'user', 'text', ?, 'sent', 'local', 1)
            """, arguments: ["m\(suffix)", "u\(suffix)", "你好\(suffix)"])
        }
    }

    // MARK: - 创建与校验

    func testCreateEncryptedBackupAndVerify() async throws {
        try await seedConversationAndMessage()
        let service = makeService()

        let manifest = try await service.createBackup(kind: .manual, note: "首次备份")
        XCTAssertTrue(manifest.isEncrypted)
        XCTAssertEqual(manifest.encryptionHint, "test-xor")
        XCTAssertEqual(manifest.status, .completed)
        XCTAssertGreaterThan(manifest.byteSize, 0)
        XCTAssertNotNil(manifest.sha256)

        let snapshot = try await service.readSnapshot(manifestID: manifest.id)
        let backupMessages = snapshot.counts["messages"]
        let backupConversations = snapshot.counts["conversations"]
        let backupSchema = snapshot.schemaVersion
        XCTAssertEqual(backupMessages, 1)
        XCTAssertEqual(backupConversations, 1)
        XCTAssertEqual(backupSchema, database.currentSchemaVersion)

        let verification = try await service.verify(manifestID: manifest.id)
        XCTAssertTrue(verification.sha256Matches)
        XCTAssertTrue(verification.decrypted)
        let verified = try await repo.manifest(id: manifest.id)
        XCTAssertEqual(verified?.status, .verified)
    }

    func testPlaintextBackupRequiresExplicitChoice() async throws {
        try await seedConversationAndMessage()
        let service = makeService()
        let manifest = try await service.createBackup(kind: .external, encrypted: false)
        XCTAssertFalse(manifest.isEncrypted)
        XCTAssertTrue(manifest.fileName.hasSuffix(".json"))
        XCTAssertNil(manifest.encryptionHint)

        let snapshot = try await service.readSnapshot(manifestID: manifest.id)
        let plaintextMessages = snapshot.counts["messages"]
        XCTAssertEqual(plaintextMessages, 1)
    }

    func testWrongKeyCannotDecrypt() async throws {
        try await seedConversationAndMessage()
        let manifest = try await makeService().createBackup(kind: .manual)

        let otherStore = MemoryKeyStore(key: Data(repeating: 9, count: 32))
        do {
            _ = try await makeService(store: otherStore).readSnapshot(manifestID: manifest.id)
            XCTFail("密钥不对必须解密失败")
        } catch let error as BackupCipherError {
            XCTAssertEqual(error, .authenticationFailed)
        }
    }

    // MARK: - 恢复

    func testRestoreReplacesDataAndKeepsSafetyBackup() async throws {
        try await seedConversationAndMessage("1")
        let service = makeService()
        let manifest = try await service.createBackup(kind: .manual)

        try await seedConversationAndMessage("2")
        let beforeRestore = try await int("SELECT count(*) FROM messages")
        XCTAssertEqual(beforeRestore, 2)

        let log = try await service.restore(manifestID: manifest.id)
        XCTAssertEqual(log.status, "completed")
        XCTAssertNotNil(log.safetyBackupID)
        XCTAssertEqual(log.backupID, manifest.id)

        let afterRestore = try await int("SELECT count(*) FROM messages")
        XCTAssertEqual(afterRestore, 1, "恢复后应回到备份时状态")
        let ftsCount = try await int("SELECT count(*) FROM message_fts")
        XCTAssertEqual(ftsCount, 1, "恢复后必须重建全文索引")

        let safetyID = try XCTUnwrap(log.safetyBackupID)
        let safety = try await repo.manifest(id: safetyID)
        XCTAssertEqual(safety?.kind, .safety, "恢复前必须自动留安全备份")
    }

    func testRestoreFailureKeepsOriginalData() async throws {
        try await seedConversationAndMessage("1")
        let service = makeService()
        let manifest = try await service.createBackup(kind: .external, encrypted: false)

        // 篡改备份：插入一条外键不存在的消息，恢复必须整体回滚
        let url = service.backupsDirectory.appendingPathComponent(manifest.fileName)
        var snapshot = try await service.readSnapshot(manifestID: manifest.id)
        let index = try XCTUnwrap(snapshot.tables.firstIndex { $0.name == "messages" })
        var table = snapshot.tables[index]
        let badRow: [BackupValue] = table.columns.map { column in
            switch column {
            case "id": return .text("bad-1")
            case "client_uuid": return .text("bad-uuid")
            case "conversation_id": return .text("missing-conversation")
            case "role": return .text("user")
            case "kind": return .text("text")
            case "text": return .text("坏行")
            case "status": return .text("sent")
            case "origin": return .text("local")
            case "created_at": return .integer(1)
            default: return .null
            }
        }
        table.rows.append(badRow)
        snapshot.tables[index] = table
        try JSONEncoder().encode(snapshot).write(to: url)

        do {
            _ = try await service.restore(manifestID: manifest.id)
            XCTFail("外键失败必须抛错")
        } catch {
            // 预期：事务回滚
        }

        let remainingMessages = try await int("SELECT count(*) FROM messages")
        XCTAssertEqual(remainingMessages, 1, "恢复失败不得破坏原数据")
        let originalText = try await string("SELECT text FROM messages")
        XCTAssertEqual(originalText, "你好1")
        let logs = try await repo.restoreLogs(limit: 5)
        XCTAssertEqual(logs.first?.status, "failed")
        XCTAssertNotNil(logs.first?.error)
    }

    func testPreviewRejectsIncompatibleSchema() async throws {
        try await seedConversationAndMessage()
        let service = makeService()
        let manifest = try await service.createBackup(kind: .external, encrypted: false)

        let url = service.backupsDirectory.appendingPathComponent(manifest.fileName)
        var snapshot = try await service.readSnapshot(manifestID: manifest.id)
        snapshot.schemaVersion = "v1_phase1"
        try JSONEncoder().encode(snapshot).write(to: url)

        let precheck = try await service.previewRestore(manifestID: manifest.id)
        XCTAssertFalse(precheck.isCompatible)
        do {
            _ = try await service.restore(manifestID: manifest.id)
            XCTFail("版本不兼容必须拒绝恢复")
        } catch let error as BackupError {
            XCTAssertEqual(error, .incompatibleSchema("v1_phase1"))
        }
    }

    func testPruneKeepsVerifiedAndSafety() async throws {
        let manual = try await makeService().createBackup(kind: .manual, at: now - 5_000)
        let automatic = try await makeService().createBackup(kind: .automatic, at: now - 4_000)
        let safety = try await makeService().createBackup(kind: .safety, at: now - 3_000)
        _ = try await makeService().verify(manifestID: manual.id)

        let prunable = try await repo.prunable(keepCount: 0, at: now)
        XCTAssertFalse(prunable.contains { $0.id == manual.id }, "已验证备份不自动清理")
        XCTAssertFalse(prunable.contains { $0.id == safety.id }, "安全备份不自动清理")
        XCTAssertTrue(prunable.contains { $0.id == automatic.id })
    }

    private func int(_ sql: String) async throws -> Int {
        try await database.dbQueue.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }

    private func string(_ sql: String) async throws -> String? {
        try await database.dbQueue.read { db in try String.fetchOne(db, sql: sql) }
    }
}
