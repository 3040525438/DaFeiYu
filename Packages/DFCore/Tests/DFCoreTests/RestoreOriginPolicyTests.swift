import XCTest
@testable import DFCore

/// D72：跨设备恢复判定——替换需确认、不合并、版本与保护备份门禁。
final class RestoreOriginPolicyTests: XCTestCase {
    private func facts(
        backupDeviceID: String? = "device-a",
        currentDeviceID: String? = "device-a",
        backupSchema: String = "v14_message_organization",
        currentSchema: String = "v14_message_organization",
        spaceOK: Bool = true,
        safetyBackup: Bool = true
    ) -> RestoreFacts {
        RestoreFacts(
            backupDeviceID: backupDeviceID,
            currentDeviceID: currentDeviceID,
            backupSchemaVersion: backupSchema,
            currentSchemaVersion: currentSchema,
            isSpaceOK: spaceOK,
            hasSafetyBackup: safetyBackup
        )
    }

    // MARK: - 来源

    func testOriginClassification() {
        XCTAssertEqual(RestoreOriginPolicy.origin(backupDeviceID: "a", currentDeviceID: "a"), .sameDevice)
        XCTAssertEqual(RestoreOriginPolicy.origin(backupDeviceID: "a", currentDeviceID: "b"), .otherDevice)
        XCTAssertEqual(RestoreOriginPolicy.origin(backupDeviceID: nil, currentDeviceID: "a"), .unknown)
        XCTAssertEqual(RestoreOriginPolicy.origin(backupDeviceID: "  ", currentDeviceID: "a"), .unknown)
        XCTAssertEqual(RestoreOriginPolicy.origin(backupDeviceID: "a", currentDeviceID: nil), .unknown)
    }

    // MARK: - 决策

    func testSameDeviceCompatibleIsAllowed() {
        XCTAssertEqual(RestoreOriginPolicy.decision(facts: facts()), .allowed)
    }

    func testOtherDeviceRequiresConfirmationAndSaysNoMerge() {
        let decision = RestoreOriginPolicy.decision(facts: facts(backupDeviceID: "device-b"))
        guard case .requiresConfirmation(let reason) = decision else {
            return XCTFail("其他设备应要求确认，实际 \(decision)")
        }
        XCTAssertTrue(reason.contains("整体替换"))
        XCTAssertTrue(reason.contains("不会自动合并"))
        XCTAssertTrue(reason.contains("保护备份"))
        XCTAssertFalse(decision.canProceedWithoutPrompt)
    }

    func testUnknownOriginRequiresConfirmation() {
        let decision = RestoreOriginPolicy.decision(facts: facts(backupDeviceID: nil))
        guard case .requiresConfirmation = decision else {
            return XCTFail("来源未知应要求确认，实际 \(decision)")
        }
    }

    func testNewerBackupSchemaIsBlocked() {
        let decision = RestoreOriginPolicy.decision(
            facts: facts(backupSchema: "v15_future", currentSchema: "v14_message_organization")
        )
        guard case .blocked(let reason) = decision else {
            return XCTFail("备份结构更新时应拒绝，实际 \(decision)")
        }
        XCTAssertTrue(reason.contains("请先升级 App"))
        XCTAssertTrue(decision.isBlocked)
    }

    func testOlderBackupSchemaIsAllowedOnSameDevice() {
        XCTAssertEqual(
            RestoreOriginPolicy.decision(
                facts: facts(backupSchema: "v13_cost_ledger", currentSchema: "v14_message_organization")
            ),
            .allowed
        )
    }

    func testFreshInstallCanRestoreAnyBackup() {
        let decision = RestoreOriginPolicy.decision(
            facts: facts(
                backupDeviceID: "device-b",
                currentDeviceID: "device-c",
                backupSchema: "v14_message_organization",
                currentSchema: "none"
            )
        )
        guard case .requiresConfirmation = decision else {
            return XCTFail("全新安装恢复其他设备备份应要求确认，实际 \(decision)")
        }
    }

    func testInsufficientSpaceIsBlocked() {
        let decision = RestoreOriginPolicy.decision(facts: facts(spaceOK: false))
        guard case .blocked(let reason) = decision else {
            return XCTFail("空间不足应拒绝，实际 \(decision)")
        }
        XCTAssertTrue(reason.contains("存储空间不足"))
    }

    func testMissingSafetyBackupIsBlocked() {
        let decision = RestoreOriginPolicy.decision(facts: facts(safetyBackup: false))
        guard case .blocked(let reason) = decision else {
            return XCTFail("没有保护备份应拒绝，实际 \(decision)")
        }
        XCTAssertTrue(reason.contains("保护备份"))
    }

    func testBlockedChecksTakePrecedenceOverOrigin() {
        // 即使来源是本机，版本更新也必须拒绝
        let decision = RestoreOriginPolicy.decision(
            facts: facts(backupSchema: "v15_future", currentSchema: "v14_message_organization")
        )
        XCTAssertTrue(decision.isBlocked)
    }

    // MARK: - 版本比较

    func testVersionComparison() {
        XCTAssertTrue(RestoreOriginPolicy.isVersion("v14_message_organization", atLeast: "v13_cost_ledger"))
        XCTAssertTrue(RestoreOriginPolicy.isVersion("v14_message_organization", atLeast: "v14_message_organization"))
        XCTAssertFalse(RestoreOriginPolicy.isVersion("v13_cost_ledger", atLeast: "v14_message_organization"))
        XCTAssertTrue(RestoreOriginPolicy.isVersion("2.0.0", atLeast: "1.9.9"))
        XCTAssertFalse(RestoreOriginPolicy.isVersion("1.9.9", atLeast: "2.0.0"))
        XCTAssertTrue(RestoreOriginPolicy.isVersion("v14", atLeast: "v9"))
    }

    func testEmptyOrNoneSchemaCountsAsOldest() {
        XCTAssertTrue(RestoreOriginPolicy.isVersion("v1", atLeast: "none"))
        XCTAssertTrue(RestoreOriginPolicy.isVersion("v1", atLeast: ""))
        XCTAssertFalse(RestoreOriginPolicy.isVersion("none", atLeast: "v1"))
    }
}
