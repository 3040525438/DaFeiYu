import XCTest
import GRDB
import DFCore
@testable import DFData

/// W9：口令解锁、失败保护、生物识别、授权记录、删除清单
final class PrivacyGateServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var privacy: PrivacyGateService!
    private let now: Int64 = 1_000_000

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFPrivacy-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        privacy = PrivacyGateService(database: database, now: { self.now })
    }

    override func tearDownWithError() throws {
        privacy = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 口令

    func testConfigureAndUnlock() async throws {
        try await privacy.configurePasscode("123456", biometrics: true)
        let settings = try await privacy.settings()
        XCTAssertTrue(settings.lockEnabled)
        XCTAssertTrue(settings.biometricsEnabled)
        XCTAssertNotNil(settings.passcodeHash)
        let cloudGranted = try await privacy.isGranted(.cloudModel)
        XCTAssertFalse(cloudGranted)

        let launch = try await privacy.handleLaunch()
        XCTAssertEqual(launch, .requiresUnlock(.launch))

        let wrong = try await privacy.attemptPasscode("000000")
        XCTAssertEqual(wrong, .wrongPasscode(remainingAttempts: 4))

        let right = try await privacy.attemptPasscode("123456")
        XCTAssertEqual(right, .unlocked)
        let state = try await privacy.state()
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.failedAttempts, 0)
    }

    func testFailuresTriggerLockout() async throws {
        try await privacy.configurePasscode("123456", biometrics: true)
        var settings = try await privacy.settings()
        settings.maxFailedAttempts = 2
        settings.lockoutSeconds = 60
        try await privacy.saveSettings(settings)
        _ = try await privacy.handleLaunch()

        let first = try await privacy.attemptPasscode("bad")
        XCTAssertEqual(first, .wrongPasscode(remainingAttempts: 1))

        let second = try await privacy.attemptPasscode("bad")
        XCTAssertEqual(second, .lockedOut(until: now + 60_000))

        let blocked = try await privacy.attemptPasscode("123456")
        XCTAssertEqual(blocked, .lockedOut(until: now + 60_000), "冷却期内正确口令也不放行")

        let blockedAgain = try await privacy.biometricUnlocked()
        XCTAssertEqual(blockedAgain, .unlocked, "生物识别成功可解开锁定状态")
    }

    func testBiometricsOnlyWhenEnabled() async throws {
        try await privacy.configurePasscode("123456", biometrics: false)
        _ = try await privacy.handleLaunch()
        let outcome = try await privacy.biometricUnlocked()
        XCTAssertEqual(outcome, .notConfigured)
    }

    func testNotConfiguredWhenGateDisabled() async throws {
        let outcome = try await privacy.attemptPasscode("123456")
        XCTAssertEqual(outcome, .notConfigured)
        let launch = try await privacy.handleLaunch()
        XCTAssertEqual(launch, .allowed)
    }

    func testBackgroundDelayLocksOnForeground() async throws {
        try await privacy.configurePasscode("123456")
        var settings = try await privacy.settings()
        settings.lockDelaySeconds = 30
        try await privacy.saveSettings(settings)

        _ = try await privacy.handleLaunch(at: now)
        _ = try await privacy.attemptPasscode("123456", at: now)

        _ = try await privacy.handleBackground(at: now + 1_000)
        let early = try await privacy.handleForeground(at: now + 20_000)
        XCTAssertEqual(early, .allowed, "未到延迟不应锁定")

        let late = try await privacy.handleForeground(at: now + 40_000)
        XCTAssertEqual(late, .requiresUnlock(.foreground))
    }

    // MARK: - 授权记录

    func testConsentRecordsAreRecordedAndRevocable() async throws {
        let denied = try await privacy.setConsent(.cloudModel, granted: false, note: "先不用云端")
        XCTAssertFalse(denied.granted)
        XCTAssertEqual(denied.updatedAt, now)
        let deniedState = try await privacy.isGranted(.cloudModel)
        XCTAssertFalse(deniedState)

        _ = try await privacy.setConsent(.cloudModel, granted: true, note: "允许本轮使用")
        let grantedState = try await privacy.isGranted(.cloudModel)
        XCTAssertTrue(grantedState)

        let all = try await privacy.consents()
        XCTAssertEqual(all.count, 1, "同类型只保留一条最新记录")
        XCTAssertEqual(all.first?.note, "允许本轮使用")
    }

    // MARK: - 数据删除

    func testDeletionPlanAndDeleteAll() async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO conversations (id, title, kind, created_at, updated_at)
            VALUES ('c1', '主会话', 'main', 1, 1)
            """)
            try db.execute(sql: """
            INSERT INTO messages (id, client_uuid, conversation_id, role, kind, text, status, origin, created_at)
            VALUES ('m1', 'u1', 'c1', 'user', 'text', '你好', 'sent', 'local', 1)
            """)
            try db.execute(sql: """
            INSERT INTO memories (id, type, title, content, importance, salience, confidence,
                                  status, first_seen_at, scope, layer, category, classification_status,
                                  created_at, updated_at)
            VALUES ('mem1', 'fact', '喜欢桂花', '用户喜欢桂花', 'normal', 0.5, 0.6,
                    'active', 1, 'user', 'semantic', 'preference', 'confirmed', 1, 1)
            """)
        }

        let plan = try await privacy.deletionPlan()
        XCTAssertGreaterThan(plan.totalCount, 0)
        XCTAssertTrue(plan.items.contains { $0.id == "messages" && $0.count == 1 })
        XCTAssertTrue(plan.items.contains { $0.id == "memories" && $0.count == 1 })
        XCTAssertEqual(plan.keyLossWarning, DataDeletionPlan.keyLossWarningText)

        do {
            _ = try await privacy.deleteAll(confirmation: "删除全部数据")
            XCTFail("确认短语不正确必须拒绝")
        } catch let error as PrivacyError {
            XCTAssertEqual(error, .confirmationMismatch)
        }
        let stillThere = try await int("SELECT count(*) FROM messages")
        XCTAssertEqual(stillThere, 1)

        let counts = try await privacy.deleteAll(confirmation: DataDeletionPlan.confirmationPhrase)
        XCTAssertEqual(counts["messages"], 1)
        XCTAssertEqual(counts["memories"], 1)

        let messages = try await int("SELECT count(*) FROM messages")
        let conversations = try await int("SELECT count(*) FROM conversations")
        let memories = try await int("SELECT count(*) FROM memories")
        XCTAssertEqual(messages, 0)
        XCTAssertEqual(conversations, 0)
        XCTAssertEqual(memories, 0)
        let fts = try await int("SELECT count(*) FROM memory_fts")
        XCTAssertEqual(fts, 0)
    }

    private func int(_ sql: String) async throws -> Int {
        try await database.dbQueue.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }
}
