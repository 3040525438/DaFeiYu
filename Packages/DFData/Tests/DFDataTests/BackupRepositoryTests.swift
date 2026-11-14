import XCTest
import GRDB
import DFCore
@testable import DFData

/// W9-2 / W9-3：备份清单、恢复日志、保留策略与失败保护。
final class BackupRepositoryTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var repo: GRDBBackupRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        repo = GRDBBackupRepository(database: database)
    }

    override func tearDownWithError() throws {
        repo = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeBackup(
        _ kind: BackupKind = .manual,
        at millis: Int64 = 1000
    ) async throws -> BackupManifest {
        try await repo.create(
            kind: kind,
            scope: "full",
            schemaVersion: "v11_local_models",
            appVersion: "2.0-lab",
            fileName: "backup-\(millis).zip",
            relPath: "backups/\(millis).zip",
            isEncrypted: true,
            encryptionHint: "用户口令",
            note: nil,
            at: millis
        )
    }

    func testCreatePendingThenFinish() async throws {
        let created = try await makeBackup()
        XCTAssertEqual(created.status, .pending)
        XCTAssertTrue(created.isEncrypted, "默认必须加密")
        XCTAssertFalse(created.isUsable)

        try await repo.markFinished(id: created.id, byteSize: 2048, sha256: "sha-1", itemCountsJSON: "{\"messages\":10}", at: 2000)
        let finished = try await repo.manifest(id: created.id)
        XCTAssertEqual(finished?.status, .completed)
        XCTAssertEqual(finished?.byteSize, 2048)
        XCTAssertEqual(finished?.sha256, "sha-1")
        XCTAssertTrue(finished?.isUsable == true)
    }

    func testMarkFailedAndVerified() async throws {
        let failed = try await makeBackup(at: 1000)
        try await repo.markFailed(id: failed.id, at: 1500)
        let failedRow = try await repo.manifest(id: failed.id)
        XCTAssertEqual(failedRow?.status, .failed)

        let verified = try await makeBackup(at: 2000)
        try await repo.markFinished(id: verified.id, byteSize: 10, sha256: nil, itemCountsJSON: "{}", at: 2100)
        try await repo.markVerified(id: verified.id, at: 2200)
        let verifiedRow = try await repo.manifest(id: verified.id)
        XCTAssertEqual(verifiedRow?.status, .verified)
        XCTAssertEqual(verifiedRow?.verifiedAt, 2200)
    }

    func testLatestByKindAndMissingID() async throws {
        _ = try await makeBackup(.manual, at: 1000)
        let newer = try await makeBackup(.manual, at: 2000)
        _ = try await makeBackup(.automatic, at: 3000)

        let latestManual = try await repo.latest(kind: .manual)
        XCTAssertEqual(latestManual?.id, newer.id)
        let latestAny = try await repo.latest(kind: nil)
        XCTAssertEqual(latestAny?.createdAt, 3000)
        let missing = try await repo.manifest(id: "nope")
        XCTAssertNil(missing)
    }

    func testPrunableKeepsRecentAndProtectsVerifiedAndSafety() async throws {
        var ids: [String] = []
        for index in 0..<5 {
            let manifest = try await makeBackup(at: Int64(1000 + index))
            try await repo.markFinished(
                id: manifest.id, byteSize: 1, sha256: nil, itemCountsJSON: "{}",
                at: Int64(2000 + index)
            )
            ids.append(manifest.id)
        }
        // 一份已验证（受保护）与一份 safety（受保护）
        try await repo.markVerified(id: ids[4], at: 3000)
        let safety = try await makeBackup(.safety, at: 4000)
        try await repo.markFinished(id: safety.id, byteSize: 1, sha256: nil, itemCountsJSON: "{}", at: 4100)

        let prunable = try await repo.prunable(keepCount: 1, at: 5000)
        // 5 份 completed 中 ids[4] 已验证被排除，剩 4 份保留最近 1 份（ids[2]），可清理 ids[0]、ids[1]
        XCTAssertEqual(Set(prunable.map(\.id)), Set([ids[0], ids[1]]))
    }

    func testStartRestoreRejectsRunningTask() async throws {
        let manifest = try await makeBackup()
        _ = try await repo.startRestore(
            backupID: manifest.id, mode: "replace", previewJSON: "{}",
            isCompatible: true, isSpaceOK: true, safetyBackupID: nil, at: 1000
        )
        do {
            _ = try await repo.startRestore(
                backupID: manifest.id, mode: "replace", previewJSON: "{}",
                isCompatible: true, isSpaceOK: true, safetyBackupID: nil, at: 1100
            )
            XCTFail("已有进行中的恢复必须拒绝")
        } catch let error as BackupError {
            XCTAssertEqual(error, .restoreAlreadyRunning)
        }
    }

    func testStartRestoreRejectsIncompatibleAndNoSpace() async throws {
        do {
            _ = try await repo.startRestore(
                backupID: "b1", mode: "new_copy", previewJSON: "{}",
                isCompatible: false, isSpaceOK: true, safetyBackupID: nil, at: 1000
            )
            XCTFail("版本不兼容必须拒绝")
        } catch let error as BackupError {
            XCTAssertEqual(error, .incompatibleSchema("b1"))
        }
        do {
            _ = try await repo.startRestore(
                backupID: "b1", mode: "new_copy", previewJSON: "{}",
                isCompatible: true, isSpaceOK: false, safetyBackupID: nil, at: 1000
            )
            XCTFail("空间不足必须拒绝")
        } catch let error as BackupError {
            XCTAssertEqual(error, .insufficientSpace)
        }
    }

    func testFinishRestoreRecordsResult() async throws {
        let log = try await repo.startRestore(
            backupID: nil, mode: "new_copy", previewJSON: "{\"messages\":3}",
            isCompatible: true, isSpaceOK: true, safetyBackupID: nil, at: 1000
        )
        try await repo.finishRestore(
            id: log.id, status: "completed", restoredCountsJSON: "{\"messages\":3}",
            error: nil, at: 2000
        )
        let logs = try await repo.restoreLogs(limit: 10)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].status, "completed")
        XCTAssertEqual(logs[0].finishedAt, 2000)
        XCTAssertEqual(logs[0].previewJSON, "{\"messages\":3}")
    }

    func testTotalBytesCountsUsableBackupsOnly() async throws {
        let completed = try await makeBackup(.manual, at: 1000)
        try await repo.markFinished(id: completed.id, byteSize: 300, sha256: nil, itemCountsJSON: "{}", at: 1100)
        let verified = try await makeBackup(.manual, at: 2000)
        try await repo.markFinished(id: verified.id, byteSize: 700, sha256: nil, itemCountsJSON: "{}", at: 2100)
        try await repo.markVerified(id: verified.id, at: 2200)
        let pending = try await makeBackup(.manual, at: 3000)

        let total = try await repo.totalBytes()
        XCTAssertEqual(total, 1000, "未完成的备份不计入占用")
        XCTAssertEqual(pending.status, .pending)
    }

    func testDeleteRemovesManifest() async throws {
        let manifest = try await makeBackup()
        try await repo.delete(id: manifest.id)
        let after = try await repo.manifest(id: manifest.id)
        XCTAssertNil(after)
    }
}
