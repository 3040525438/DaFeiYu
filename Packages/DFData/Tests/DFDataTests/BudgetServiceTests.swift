import XCTest
import GRDB
import DFCore
@testable import DFData

/// D10：成本记账与预算闸门（边界 / 并发 / 失败重试 / 跨日重置 / 审计）
final class BudgetServiceTests: XCTestCase {
    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        init(_ value: Int64) { self.value = value }
        func now() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func advance(hours: Int64) {
            lock.lock()
            value += hours * 3_600_000
            lock.unlock()
        }
    }

    private var root: URL!
    private var database: AppDatabase!
    private var settings: GRDBSettingsRepository!
    private var clock: MutableClock!
    private var service: BudgetService!

    /// 2026-11-15 10:00:00 +08:00
    private let startMillis: Int64 = 1_763_172_000_000

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFBudget-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        settings = GRDBSettingsRepository(database: database)
        clock = MutableClock(startMillis)
        let sharedClock = clock!
        service = BudgetService(
            database: database,
            settings: settings,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            now: { sharedClock.now() }
        )
    }

    override func tearDownWithError() throws {
        service = nil
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private let pricing = ModelPricing(inputPerThousandYuan: 1, outputPerThousandYuan: 2)

    // MARK: - 配置

    func testLimitsAndPricingRoundTrip() async throws {
        let defaults = try await service.limits()
        XCTAssertEqual(defaults, .default)

        try await service.saveLimits(
            BudgetLimits(dailyYuan: 3, perCallYuan: 0.5, autonomyDailyYuan: 1, unknownReserveYuan: 0.1)
        )
        let loaded = try await service.limits()
        XCTAssertEqual(loaded.dailyYuan, 3)
        XCTAssertEqual(loaded.perCallYuan, 0.5)
        XCTAssertEqual(loaded.autonomyDailyYuan, 1)
        XCTAssertEqual(loaded.unknownReserveYuan, 0.1)

        try await service.savePricing(pricing, modelID: "gpt-x")
        let stored = try await service.pricing(modelID: "gpt-x")
        XCTAssertEqual(stored, pricing)
        let missing = try await service.pricing(modelID: "unknown")
        XCTAssertNil(missing)
    }

    // MARK: - 结算口径

    func testConfirmedCostUsesServerUsageAndPricing() async throws {
        try await service.saveLimits(BudgetLimits(dailyYuan: 10))
        try await service.savePricing(pricing, modelID: "gpt-x")

        let reservation = try await service.reserve(
            scope: .chat,
            estimatedYuan: 0.1,
            provider: "openaiCompatible",
            modelID: "gpt-x",
            refID: "m-1"
        )
        let record = try await service.settle(
            reservationID: reservation,
            usage: Usage(promptTokens: 1000, completionTokens: 500),
            pricing: pricing,
            fallbackPromptTokens: 0,
            fallbackCompletionTokens: 0
        )

        XCTAssertEqual(record.costKind, .confirmed)
        XCTAssertEqual(record.costYuan ?? -1, 2.0, accuracy: 0.0001)
        XCTAssertEqual(record.status, "settled")
        XCTAssertEqual(record.refID, "m-1")

        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.confirmedYuan, 2.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.estimatedYuan, 0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.unknownCount, 0)
    }

    func testSettleWithoutPricingIsUnavailableNotEmptyZero() async throws {
        try await service.saveLimits(BudgetLimits(dailyYuan: 1, unknownReserveYuan: 0.5))
        let reservation = try await service.reserve(
            scope: .chat,
            estimatedYuan: 0,
            provider: "openaiCompatible",
            modelID: "no-price"
        )
        let record = try await service.settle(
            reservationID: reservation,
            usage: Usage(promptTokens: 100, completionTokens: 50),
            pricing: nil,
            fallbackPromptTokens: 0,
            fallbackCompletionTokens: 0
        )

        XCTAssertEqual(record.costKind, .unavailable)
        XCTAssertNil(record.costYuan, "无法计量必须记 NULL，不能写 0")

        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.unknownCount, 1)
        XCTAssertEqual(snapshot.knownTotalYuan, 0)
        XCTAssertEqual(snapshot.effectiveYuan(unknownReserveYuan: 0.5), 0.5, accuracy: 0.0001)

        // 未知费用按保守值占掉预算后，新的调用必须被拦
        do {
            _ = try await service.reserve(
                scope: .chat,
                estimatedYuan: 0.6,
                provider: "openaiCompatible",
                modelID: "no-price"
            )
            XCTFail("未知费用不得按 0 计算，应已超出每日预算")
        } catch let error as BudgetError {
            guard case .blocked = error else { return XCTFail("应抛出预算拦截") }
        }
    }

    func testSettleWithoutUsageIsEstimated() async throws {
        let reservation = try await service.reserve(
            scope: .chat,
            estimatedYuan: 0.1,
            provider: "openaiCompatible",
            modelID: "gpt-x"
        )
        let record = try await service.settle(
            reservationID: reservation,
            usage: nil,
            pricing: pricing,
            fallbackPromptTokens: 500,
            fallbackCompletionTokens: 250
        )

        XCTAssertEqual(record.costKind, .estimated)
        XCTAssertEqual(record.costYuan ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(record.promptTokens, 500)
        XCTAssertEqual(record.completionTokens, 250)
    }

    // MARK: - 边界

    func testDailyLimitBoundaryInsideService() async throws {
        try await service.saveLimits(BudgetLimits(dailyYuan: 1))

        _ = try await service.reserve(
            scope: .chat, estimatedYuan: 0.6, provider: "p", modelID: "m"
        )
        // 0.6 + 0.4 = 1.0，刚好等于上限，放行
        _ = try await service.reserve(
            scope: .chat, estimatedYuan: 0.4, provider: "p", modelID: "m"
        )
        // 0.6 + 0.4 + 0.01 > 1，拦截
        do {
            _ = try await service.reserve(
                scope: .chat, estimatedYuan: 0.01, provider: "p", modelID: "m"
            )
            XCTFail("超过每日预算必须拦截")
        } catch let error as BudgetError {
            guard case .blocked = error else { return XCTFail("应抛出预算拦截") }
        }

        let records = try await service.records()
        XCTAssertEqual(records.count, 2, "被拦截的调用不得留下记录")
    }

    func testPerCallLimitBlocksBeforeInsert() async throws {
        try await service.saveLimits(BudgetLimits(dailyYuan: 10, perCallYuan: 0.2))
        do {
            _ = try await service.reserve(
                scope: .chat, estimatedYuan: 0.21, provider: "p", modelID: "m"
            )
            XCTFail("单次上限必须生效")
        } catch let error as BudgetError {
            guard case .blocked(let reason) = error else { return XCTFail("应抛出预算拦截") }
            XCTAssertTrue(reason.contains("单次上限"))
        }
        let records = try await service.records()
        XCTAssertTrue(records.isEmpty)
    }

    // MARK: - 并发

    func testConcurrentReservationsCannotBypassDailyLimit() async throws {
        try await service.saveLimits(BudgetLimits(dailyYuan: 1))

        let sharedService = service!
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    do {
                        _ = try await sharedService.reserve(
                            scope: .chat, estimatedYuan: 0.3, provider: "p", modelID: "m"
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }

        XCTAssertEqual(successes, 3, "每日 1 元、每次 0.3 元，最多只能放行 3 次")
        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.estimatedYuan, 0.9, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(snapshot.estimatedYuan, 1)
    }

    // MARK: - 失败与重试

    func testFailedReservationKeepsConservativeCharge() async throws {
        try await service.saveLimits(BudgetLimits(dailyYuan: 1))
        let reservation = try await service.reserve(
            scope: .autonomy, estimatedYuan: 0.2, provider: "p", modelID: "m"
        )
        try await service.fail(reservationID: reservation, reason: "网络中断")

        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.estimatedYuan, 0.2, accuracy: 0.0001)
        XCTAssertEqual(snapshot.autonomyYuan, 0.2, accuracy: 0.0001)

        let records = try await service.records()
        XCTAssertEqual(records.first?.status, "failed")
        XCTAssertTrue(records.first?.note?.contains("网络中断") == true)

        // 失败后再次尝试，仍受限
        do {
            _ = try await service.reserve(
                scope: .autonomy, estimatedYuan: 0.9, provider: "p", modelID: "m"
            )
            XCTFail("失败调用按保守金额计入后应超预算")
        } catch let error as BudgetError {
            guard case .blocked = error else { return XCTFail("应抛出预算拦截") }
        }
    }

    func testCancelReleasesReservation() async throws {
        try await service.saveLimits(BudgetLimits(dailyYuan: 1))
        let reservation = try await service.reserve(
            scope: .chat, estimatedYuan: 0.6, provider: "p", modelID: "m"
        )
        try await service.cancel(reservationID: reservation, reason: "用户取消")

        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.estimatedYuan, 0, accuracy: 0.0001)

        _ = try await service.reserve(
            scope: .chat, estimatedYuan: 0.9, provider: "p", modelID: "m"
        )
    }

    func testSettleTwiceIsRejected() async throws {
        let reservation = try await service.reserve(
            scope: .chat, estimatedYuan: 0.1, provider: "p", modelID: "m"
        )
        _ = try await service.settle(
            reservationID: reservation,
            usage: Usage(promptTokens: 10, completionTokens: 10),
            pricing: pricing,
            fallbackPromptTokens: 0,
            fallbackCompletionTokens: 0
        )
        do {
            _ = try await service.settle(
                reservationID: reservation,
                usage: nil,
                pricing: pricing,
                fallbackPromptTokens: 0,
                fallbackCompletionTokens: 0
            )
            XCTFail("重复结算必须被拒绝")
        } catch let error as BudgetError {
            XCTAssertEqual(error, .alreadyFinished(reservation))
        }
    }

    // MARK: - 跨日重置

    func testBudgetResetsAcrossDay() async throws {
        try await service.saveLimits(BudgetLimits(dailyYuan: 1))
        let dayA = service.dayKey()
        _ = try await service.reserve(
            scope: .chat, estimatedYuan: 0.9, provider: "p", modelID: "m"
        )
        let spendA = try await service.snapshot()
        XCTAssertEqual(spendA.estimatedYuan, 0.9, accuracy: 0.0001)

        clock.advance(hours: 24)
        let dayB = service.dayKey()
        XCTAssertNotEqual(dayA, dayB)

        let spendB = try await service.snapshot()
        XCTAssertEqual(spendB.estimatedYuan, 0, accuracy: 0.0001)
        _ = try await service.reserve(
            scope: .chat, estimatedYuan: 0.9, provider: "p", modelID: "m"
        )
        let spendBAfter = try await service.snapshot()
        XCTAssertEqual(spendBAfter.estimatedYuan, 0.9, accuracy: 0.0001)
        // 第一天的记录仍可审计
        let dayARecords = try await service.records(dayKey: dayA)
        XCTAssertEqual(dayARecords.count, 1)
    }

    // MARK: - 审计

    func testAuditRecordsKeepSourceAndKind() async throws {
        try await service.savePricing(pricing, modelID: "gpt-x")
        let reservation = try await service.reserve(
            scope: .autonomy,
            estimatedYuan: 0.2,
            provider: "openaiCompatible",
            modelID: "gpt-x",
            refID: "task-1"
        )
        _ = try await service.settle(
            reservationID: reservation,
            usage: Usage(promptTokens: 200, completionTokens: 100),
            pricing: pricing,
            fallbackPromptTokens: 0,
            fallbackCompletionTokens: 0,
            note: "自主问候"
        )

        let records = try await service.records()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.scope, .autonomy)
        XCTAssertEqual(record.refID, "task-1")
        XCTAssertEqual(record.provider, "openaiCompatible")
        XCTAssertEqual(record.modelID, "gpt-x")
        XCTAssertEqual(record.costKind, .confirmed)
        XCTAssertEqual(record.note, "自主问候")
        XCTAssertNotNil(record.settledAt)
        XCTAssertEqual(record.dayKey, service.dayKey())
    }
}
