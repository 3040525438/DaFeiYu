import XCTest
import GRDB
import DFCore
@testable import DFData

/// D67：升级前备份——文件复制、清单、保留策略，以及启动升级时的自动接线。
final class PreUpgradeBackupServiceTests: XCTestCase {
    private var root: URL!
    private var paths: DatabasePaths!

    private final class ClockBox: @unchecked Sendable {
        var value: Int64 = 1_000
    }
    private let clock = ClockBox()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFPreBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = DatabasePaths(root: root)
    }

    override func tearDownWithError() throws {
        paths = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 备份内容

    func testBackupCopiesDatabaseAndWritesManifest() async throws {
        let database = try AppDatabase(paths: paths)
        try await database.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS backup_probe (x INTEGER)")
        }

        let service = PreUpgradeBackupService(paths: paths)
        let result = try service.backup(fromVersion: "v13_cost_ledger")

        XCTAssertEqual(result.fromVersion, "v13_cost_ledger")
        XCTAssertTrue(result.id.hasSuffix("v13_cost_ledger"))
        XCTAssertTrue(result.files.contains("dafeiyu.sqlite"))
        XCTAssertTrue(result.files.contains("manifest.json"))
        XCTAssertGreaterThan(result.totalBytes, 0)
        XCTAssertTrue(result.removed.isEmpty)

        let manifestURL = result.directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["fromVersion"] as? String, "v13_cost_ledger")
        XCTAssertEqual(json?["id"] as? String, result.id)
        XCTAssertNotNil(json?["files"])
        // 备份目录本身不能带 manifest 之外的多余子目录
        XCTAssertEqual(service.existingBackupIDs(), [result.id])
    }

    func testBackupThrowsWhenDatabaseMissing() {
        let service = PreUpgradeBackupService(paths: paths)
        XCTAssertThrowsError(try service.backup(fromVersion: "v13_cost_ledger")) { error in
            XCTAssertEqual(error as? PreUpgradeBackupError, .databaseMissing("dafeiyu.sqlite"))
        }
        XCTAssertTrue(service.existingBackupIDs().isEmpty)
    }

    func testBackupExcludesSidecarFilesThatDoNotExist() async throws {
        _ = try AppDatabase(paths: paths)
        let service = PreUpgradeBackupService(paths: paths)
        let result = try service.backup(fromVersion: "v14_message_organization")

        // WAL/SHM 是否存在取决于连接状态，但复制清单与磁盘事实必须一致
        for name in ["dafeiyu.sqlite-wal", "dafeiyu.sqlite-shm"] {
            let copied = FileManager.default.fileExists(
                atPath: result.directory.appendingPathComponent(name).path
            )
            XCTAssertEqual(copied, result.files.contains(name))
        }
    }

    // MARK: - 保留策略

    func testRetentionRemovesOldestBackups() async throws {
        _ = try AppDatabase(paths: paths)
        let service = PreUpgradeBackupService(paths: paths, retention: 2, now: { self.clock.value })

        var ids: [String] = []
        var lastRemoved: [String] = []
        for _ in 0..<4 {
            clock.value += 1_000
            let result = try service.backup(fromVersion: "v13_cost_ledger")
            ids.append(result.id)
            lastRemoved = result.removed
        }

        // 第 3 份时清掉最旧，第 4 份时清掉当时最旧的 ids[1]
        XCTAssertEqual(lastRemoved, [ids[1]])
        XCTAssertEqual(service.existingBackupIDs().sorted(), Array(ids.suffix(2)).sorted())
    }

    func testSameTimestampProducesUniqueDirectories() async throws {
        _ = try AppDatabase(paths: paths)
        let service = PreUpgradeBackupService(paths: paths, now: { 5_000 })
        let first = try service.backup(fromVersion: "v13_cost_ledger")
        let second = try service.backup(fromVersion: "v13_cost_ledger")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(service.existingBackupIDs().count, 2)
    }

    // MARK: - 启动升级自动接线

    func testUpgradeOnLaunchCreatesPreUpgradeBackup() async throws {
        let old = try AppDatabase(paths: paths, makeMigrator: {
            Migrations.makeMigrator(upTo: .v13_cost_ledger)
        })
        XCTAssertEqual(old.currentSchemaVersion, "v13_cost_ledger")
        XCTAssertTrue(PreUpgradeBackupService(paths: paths).existingBackupIDs().isEmpty)

        let upgraded = try AppDatabase(paths: paths, makeMigrator: { Migrations.migrator })
        XCTAssertEqual(upgraded.currentSchemaVersion, Migrations.latest.rawValue)

        let service = PreUpgradeBackupService(paths: paths)
        let ids = service.existingBackupIDs()
        XCTAssertEqual(ids.count, 1)
        let directory = service.backupsRoot.appendingPathComponent(ids[0], isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("dafeiyu.sqlite").path
        ))
        XCTAssertTrue(ids[0].hasSuffix("v13_cost_ledger"))

        // 审计记录必须指向这份备份，且状态为成功
        let records = try await UpgradeRecordService(database: upgraded).recent(limit: 5)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.status, .succeeded)
        XCTAssertEqual(records.first?.fromVersion, "v13_cost_ledger")
        XCTAssertEqual(records.first?.toVersion, Migrations.latest.rawValue)
        XCTAssertEqual(records.first?.backupID, ids[0])
    }

    func testNoBackupWhenVersionUnchanged() async throws {
        _ = try AppDatabase(paths: paths)
        XCTAssertTrue(PreUpgradeBackupService(paths: paths).existingBackupIDs().isEmpty)

        // 第二次启动版本相同，不应再产生备份
        _ = try AppDatabase(paths: paths)
        XCTAssertTrue(PreUpgradeBackupService(paths: paths).existingBackupIDs().isEmpty)
    }
}
