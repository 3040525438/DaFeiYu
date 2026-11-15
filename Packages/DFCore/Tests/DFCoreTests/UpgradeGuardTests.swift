import XCTest
@testable import DFCore

/// D67：升级前的版本兼容判断、备份要求与升级记录状态机。
final class UpgradeGuardTests: XCTestCase {
    private let chain = ["v1_phase1", "v2_memory", "v13_cost_ledger", "v14_message_organization"]
    private let latest = "v14_message_organization"

    func testFreshInstall() {
        XCTAssertEqual(
            UpgradeGuard.plan(currentVersion: "none", knownVersions: chain, latestVersion: latest),
            .freshInstall
        )
        XCTAssertEqual(
            UpgradeGuard.plan(currentVersion: nil, knownVersions: chain, latestVersion: latest),
            .freshInstall
        )
        XCTAssertTrue(
            UpgradeGuard.requiresPreUpgradeBackup(
                UpgradeGuard.plan(currentVersion: "none", knownVersions: chain, latestVersion: latest)
            ) == false,
            "全新安装没有旧数据，不需要升级前备份"
        )
    }

    func testUpgradePlanKeepsVersions() {
        let plan = UpgradeGuard.plan(currentVersion: "v13_cost_ledger", knownVersions: chain, latestVersion: latest)
        XCTAssertEqual(plan, .upgrade(from: "v13_cost_ledger", to: latest))
        XCTAssertTrue(UpgradeGuard.requiresPreUpgradeBackup(plan))
        XCTAssertTrue(UpgradeGuard.shouldMigrate(plan))
    }

    func testUpToDateSkipsMigration() {
        let plan = UpgradeGuard.plan(currentVersion: latest, knownVersions: chain, latestVersion: latest)
        XCTAssertEqual(plan, .upToDate(version: latest))
        XCTAssertFalse(UpgradeGuard.shouldMigrate(plan))
        XCTAssertFalse(UpgradeGuard.requiresPreUpgradeBackup(plan))
    }

    func testUnknownVersionIsBlocked() {
        let plan = UpgradeGuard.plan(currentVersion: "v99_future", knownVersions: chain, latestVersion: latest)
        guard case .blocked(let reason) = plan else {
            return XCTFail("未知版本必须拒绝升级，实际 \(plan)")
        }
        XCTAssertTrue(reason.contains("已知迁移链"))
        XCTAssertFalse(UpgradeGuard.shouldMigrate(plan))
    }

    func testDowngradeIsBlocked() {
        let plan = UpgradeGuard.plan(
            currentVersion: "v14_message_organization",
            knownVersions: chain,
            latestVersion: "v13_cost_ledger"
        )
        guard case .blocked(let reason) = plan else {
            return XCTFail("库比 App 新时必须拒绝，实际 \(plan)")
        }
        XCTAssertTrue(reason.contains("比当前 App"))
    }

    func testLatestNotInChainIsBlocked() {
        let plan = UpgradeGuard.plan(
            currentVersion: "v1_phase1",
            knownVersions: chain,
            latestVersion: "v99_future"
        )
        guard case .blocked(let reason) = plan else {
            return XCTFail("目标版本不在链内必须拒绝，实际 \(plan)")
        }
        XCTAssertTrue(reason.contains("目标版本"))
    }

    func testStatusTransitions() {
        XCTAssertTrue(UpgradeGuard.canTransition(from: .running, to: .succeeded))
        XCTAssertTrue(UpgradeGuard.canTransition(from: .running, to: .failed))
        XCTAssertTrue(UpgradeGuard.canTransition(from: .failed, to: .rolledBack))
        XCTAssertFalse(UpgradeGuard.canTransition(from: .succeeded, to: .failed))
        XCTAssertFalse(UpgradeGuard.canTransition(from: .rolledBack, to: .succeeded))
        XCTAssertFalse(UpgradeGuard.canTransition(from: .running, to: .rolledBack))
    }
}
