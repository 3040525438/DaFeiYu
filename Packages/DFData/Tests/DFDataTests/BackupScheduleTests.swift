import XCTest
import GRDB
import DFCore
@testable import DFData

/// D09：自动备份调度（策略纯函数 + 服务落库行为）。
final class BackupScheduleTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var settings: GRDBSettingsRepository!

    private let now: Int64 = 1_700_000_000_000
    private let dayStart: Int64 = 1_699_900_000_000

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFBackupSchedule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        settings = GRDBSettingsRepository(database: database)
        // 空库不自动备份：先放一条真实消息，保证服务有数据可备份
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '大肥鱼', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages
                (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m0', 'u0', 'c1', 'user', 'text', '嗨', 'sent', 'user', 2)
            """)
        }
    }

    override func tearDownWithError() throws {
        settings = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 策略

    func testPolicyRunsAutomaticFirstTime() {
        let decision = BackupSchedulePolicy.default.decide(
            nowMillis: now,
            dayStartMillis: dayStart,
            lastAutomaticAt: nil,
            lastIncrementalAt: nil,
            dataChanged: true
        )
        XCTAssertEqual(decision.action, .automatic)
    }

    func testPolicyRunsAutomaticAfterDayBoundary() {
        let decision = BackupSchedulePolicy.default.decide(
            nowMillis: now,
            dayStartMillis: dayStart,
            lastAutomaticAt: dayStart - 1,
            lastIncrementalAt: now - 10 * 60 * 1000,
            dataChanged: false
        )
        XCTAssertEqual(decision.action, .automatic, "跨天后必须先做完整备份")
    }

    func testPolicySkipsWhenNothingChangedToday() {
        let decision = BackupSchedulePolicy.default.decide(
            nowMillis: now,
            dayStartMillis: dayStart,
            lastAutomaticAt: dayStart + 1000,
            lastIncrementalAt: nil,
            dataChanged: false
        )
        XCTAssertEqual(decision.action, .skip)
        XCTAssertFalse(decision.reason.isEmpty)
    }

    func testPolicyRunsIncrementalWhenDataChanged() {
        let decision = BackupSchedulePolicy.default.decide(
            nowMillis: now,
            dayStartMillis: dayStart,
            lastAutomaticAt: dayStart + 1000,
            lastIncrementalAt: now - 2 * 60 * 60 * 1000,
            dataChanged: true
        )
        XCTAssertEqual(decision.action, .incremental)
    }

    func testPolicySkipsIncrementalTooFrequent() {
        let decision = BackupSchedulePolicy.default.decide(
            nowMillis: now,
            dayStartMillis: dayStart,
            lastAutomaticAt: dayStart + 1000,
            lastIncrementalAt: now - 30 * 60 * 1000,
            dataChanged: true
        )
        XCTAssertEqual(decision.action, .skip, "增量备份必须有最小间隔")
    }

    // MARK: - 服务

    private func makeService(
        policy: BackupSchedulePolicy = .default,
        creator: @escaping BackupScheduleService.BackupCreator
    ) -> BackupScheduleService {
        let fixedNow = now
        let fixedDayStart = dayStart
        let clock = AutonomyClock(
            now: { fixedNow },
            minuteOfDay: { _ in 600 },
            dayStart: { _ in fixedDayStart }
        )
        return BackupScheduleService(
            database: database,
            settings: settings,
            policy: policy,
            clock: clock,
            createBackup: creator
        )
    }

    private static func manifest(kind: BackupKind, at millis: Int64) -> BackupManifest {
        BackupManifest(
            id: UUID().uuidString,
            kind: kind,
            scope: "all",
            status: .completed,
            schemaVersion: "v12_diary_structure",
            appVersion: "0.1.0",
            fileName: "backup-\(kind.rawValue).dfbk",
            relPath: "Backups/backup-\(kind.rawValue).dfbk",
            byteSize: 128,
            sha256: "deadbeef",
            isEncrypted: true,
            encryptionHint: nil,
            itemCountsJSON: "{}",
            note: nil,
            createdAt: millis,
            finishedAt: millis,
            verifiedAt: nil,
            retentionUntil: nil
        )
    }

    func testServiceCreatesAutomaticBackupOncePerDay() async throws {
        let millis = now
        let service = makeService { kind, _ in
            Self.manifest(kind: kind, at: millis)
        }

        let first = try await service.runIfDue()
        XCTAssertEqual(first.action, .automatic)
        XCTAssertEqual(first.manifest?.kind, .automatic)
        XCTAssertEqual(first.reason, "今天还没有自动备份")
        let lastAfterFirst = try await settings.string(for: BackupScheduleService.keyLastAutomaticAt)
        XCTAssertEqual(lastAfterFirst, String(now))
        let fingerprint = try await settings.string(for: BackupScheduleService.keyFingerprint)
        XCTAssertNotNil(fingerprint)

        let second = try await service.runIfDue()
        XCTAssertEqual(second.action, .skip)
        let lastAfterSecond = try await settings.string(for: BackupScheduleService.keyLastAutomaticAt)
        XCTAssertEqual(lastAfterSecond, lastAfterFirst, "同一天不得重复完整备份")
    }

    func testServiceCreatesIncrementalAfterDataChange() async throws {
        let millis = now
        let service = makeService { kind, _ in
            Self.manifest(kind: kind, at: millis)
        }

        _ = try await service.runIfDue()
        let firstLastAutomatic = try await settings.string(for: BackupScheduleService.keyLastAutomaticAt)
        XCTAssertNotNil(firstLastAutomatic)

        // 模拟数据变化：再插入一条消息
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO messages
                (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'u1', 'c1', 'user', 'text', '你好', 'sent', 'user', 3)
            """)
        }

        // 让"上次增量"早于最小间隔，避免被频率限制挡住
        try await settings.set(String(now - 2 * 60 * 60 * 1000), for: BackupScheduleService.keyLastIncrementalAt)

        let third = try await service.runIfDue()
        XCTAssertEqual(third.action, .incremental)
        XCTAssertEqual(third.manifest?.kind, .incremental)
        let lastIncremental = try await settings.string(for: BackupScheduleService.keyLastIncrementalAt)
        XCTAssertEqual(lastIncremental, String(now))
    }

    func testServiceRespectsDisabledSwitch() async throws {
        struct Boom: Error {}
        let service = makeService { _, _ in
            throw Boom()
        }
        try await service.setEnabled(false)

        let outcome = try await service.runIfDue()
        XCTAssertEqual(outcome.action, .skip)
        XCTAssertEqual(outcome.reason, "自动备份已关闭")
        XCTAssertNil(outcome.manifest)
        let lastAutomatic = try await settings.string(for: BackupScheduleService.keyLastAutomaticAt)
        XCTAssertNil(lastAutomatic)
    }

    func testFailureDoesNotAdvanceTimestamps() async throws {
        struct Boom: Error {}
        let service = makeService { _, _ in
            throw Boom()
        }

        do {
            _ = try await service.runIfDue()
            XCTFail("创建备份失败必须抛出")
        } catch {
            XCTAssertTrue(error is Boom)
        }

        let last = try await settings.string(for: BackupScheduleService.keyLastAutomaticAt)
        XCTAssertNil(last, "失败不得写入上次备份时间")
        let fingerprint = try await settings.string(for: BackupScheduleService.keyFingerprint)
        XCTAssertNil(fingerprint)
    }
}
