import XCTest
import GRDB
import DFCore
@testable import DFData

/// 紧迫度 / 节奏信号接入真实自主服务：拦下的结论必须写进 `autonomy_runs`。
final class AutonomyServiceRhythmTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: AutonomyService!

    private static let now: Int64 = 100_000_000
    private static let dayStart: Int64 = 90_000_000

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFAutonomyRhythm-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        service = AutonomyService(
            database: database,
            clock: AutonomyClock(
                now: { Self.now },
                minuteOfDay: { _ in 10 * 60 },
                dayStart: { _ in Self.dayStart }
            )
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testLowUrgencyIsBlockedAndRecorded() async throws {
        let result = try await service.evaluateSend(
            trigger: .message,
            urgency: 0.05,
            speakReason: .silenceConcern
        )
        XCTAssertFalse(result.decision.allowed)
        XCTAssertEqual(result.decision.reason, "反思紧迫度不足，暂不打扰")

        let runs = try await service.runs(limit: 5)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.status, .blocked)
        XCTAssertEqual(run.blockReason, "反思紧迫度不足，暂不打扰")
    }

    func testHighUrgencyIsAllowed() async throws {
        let result = try await service.evaluateSend(
            trigger: .message,
            urgency: 0.9,
            speakReason: .emotionalOverflow
        )
        XCTAssertTrue(result.decision.allowed)
        XCTAssertNil(result.decision.reason)
    }

    func testQuickCadenceBlocks() async throws {
        let quick = CadenceSignals(
            recentCount: 8,
            averageGapMinutes: 0.9,
            lastGapMinutes: 0.2,
            isQuick: true,
            isSlow: false
        )
        let result = try await service.evaluateSend(
            trigger: .message,
            urgency: 0.99,
            speakReason: .trendShare,
            cadence: quick
        )
        XCTAssertFalse(result.decision.allowed)
        XCTAssertEqual(result.decision.reason, "用户正在连续互动，暂不主动打扰")
    }

    func testNoUrgencyKeepsLegacyResult() async throws {
        let result = try await service.evaluateSend(trigger: .message)
        XCTAssertTrue(result.decision.allowed)
    }

    func testMemoryConsolidationIgnoresRhythm() async throws {
        let result = try await service.evaluateSend(
            trigger: .memoryConsolidation,
            urgency: 0,
            speakReason: .none
        )
        XCTAssertTrue(result.decision.allowed, "记忆整理不打扰用户，不受紧迫度约束")
    }
}
