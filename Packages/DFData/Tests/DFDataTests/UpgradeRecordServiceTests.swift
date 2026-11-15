import XCTest
import GRDB
import DFCore
@testable import DFData

/// D67：升级审计记录（running → succeeded/failed → rolled_back）。
final class UpgradeRecordServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: UpgradeRecordService!
    private final class ClockBox: @unchecked Sendable {
        var value: Int64 = 1_700_000_000_000
    }
    private let clock = ClockBox()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFUpgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        service = UpgradeRecordService(database: database, now: { self.clock.value })
    }

    override func tearDownWithError() throws {
        service = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testStartCreatesRunningRecord() async throws {
        let record = try await service.start(
            fromVersion: "v13_cost_ledger",
            toVersion: "v14_message_organization"
        )
        XCTAssertEqual(record.status, .running)
        XCTAssertNil(record.finishedAt)
        XCTAssertEqual(record.fromVersion, "v13_cost_ledger")

        let reloaded = try await service.record(id: record.id)
        XCTAssertEqual(reloaded?.status, .running)
        XCTAssertEqual(reloaded?.toVersion, "v14_message_organization")
    }

    func testFinishSucceeded() async throws {
        let record = try await service.start(fromVersion: "v13_cost_ledger", toVersion: "v14_message_organization")
        clock.value += 1_000
        let finished = try await service.finish(id: record.id, status: .succeeded)
        XCTAssertEqual(finished.status, .succeeded)
        XCTAssertEqual(finished.finishedAt, clock.value)
        XCTAssertTrue(finished.isFinished)
    }

    func testFailureKeepsErrorAndAllowsRollback() async throws {
        let record = try await service.start(fromVersion: "v13_cost_ledger", toVersion: "v14_message_organization")
        let failed = try await service.finish(id: record.id, status: .failed, error: "迁移失败：磁盘已满")
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.error, "迁移失败：磁盘已满")

        let rolledBack = try await service.finish(id: record.id, status: .rolledBack)
        XCTAssertEqual(rolledBack.status, .rolledBack)
    }

    func testInvalidTransitionIsRejected() async throws {
        let record = try await service.start(fromVersion: "v13_cost_ledger", toVersion: "v14_message_organization")
        _ = try await service.finish(id: record.id, status: .succeeded)
        do {
            _ = try await service.finish(id: record.id, status: .failed, error: "迟到的失败")
            XCTFail("已成功记录不允许再改为失败")
        } catch let error as UpgradeRecordService.RecordError {
            XCTAssertEqual(error, .invalidTransition(from: "succeeded", to: "failed"))
        }
    }

    func testUnknownRecordThrows() async throws {
        do {
            _ = try await service.finish(id: "missing", status: .succeeded)
            XCTFail("不存在的记录应报错")
        } catch let error as UpgradeRecordService.RecordError {
            XCTAssertEqual(error, .notFound("missing"))
        }
    }

    func testRecentReturnsNewestFirst() async throws {
        let first = try await service.start(fromVersion: "v1_phase1", toVersion: "v2_memory")
        clock.value += 5_000
        let second = try await service.start(fromVersion: "v2_memory", toVersion: "v13_cost_ledger")
        let recent = try await service.recent(limit: 10)
        XCTAssertEqual(recent.map(\.id), [second.id, first.id])
    }
}
