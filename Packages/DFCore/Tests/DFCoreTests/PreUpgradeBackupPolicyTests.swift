import XCTest
@testable import DFCore

/// D67：升级前备份策略（纯逻辑）——只判断是否需要备份、目录命名与保留清理。
final class PreUpgradeBackupPolicyTests: XCTestCase {
    func testShouldBackupOnlyWhenUpgrading() {
        XCTAssertTrue(PreUpgradeBackupPolicy.shouldBackup(.upgrade(from: "v13_cost_ledger", to: "v14_message_organization")))
        XCTAssertFalse(PreUpgradeBackupPolicy.shouldBackup(.freshInstall))
        XCTAssertFalse(PreUpgradeBackupPolicy.shouldBackup(.upToDate(version: "v14_message_organization")))
        XCTAssertFalse(PreUpgradeBackupPolicy.shouldBackup(.blocked(reason: "库比 App 新")))
    }

    func testDirectoryNameIncludesTimestampAndVersion() {
        let name = PreUpgradeBackupPolicy.directoryName(timestamp: 1_700_000_000_000, version: "v13_cost_ledger")
        XCTAssertEqual(name, "1700000000000-v13_cost_ledger")
    }

    func testDirectoryNameSanitizesUnsafeCharacters() {
        let name = PreUpgradeBackupPolicy.directoryName(timestamp: 1, version: "../etc/passwd")
        XCTAssertEqual(name, "1-___etc_passwd")
        XCTAssertFalse(name.contains("/"))
    }

    func testEmptyVersionFallsBackToUnknown() {
        XCTAssertEqual(PreUpgradeBackupPolicy.sanitized(""), "unknown")
        // 中日韩字母属于字母，允许保留
        XCTAssertEqual(PreUpgradeBackupPolicy.sanitized("中文版本"), "中文版本")
        XCTAssertEqual(PreUpgradeBackupPolicy.sanitized("  "), "___")
    }

    func testLongVersionIsTruncated() {
        let long = String(repeating: "a", count: 100)
        let safe = PreUpgradeBackupPolicy.sanitized(long)
        XCTAssertEqual(safe.count, PreUpgradeBackupPolicy.maxVersionLength)
    }

    func testExpiredKeepsNewestAndCurrent() {
        let existing = ["100-v1", "200-v2", "300-v3"]
        let expired = PreUpgradeBackupPolicy.expiredDirectoryNames(
            existing: existing,
            keeping: 2,
            current: "300-v3"
        )
        XCTAssertEqual(expired, ["100-v1"])
    }

    func testCurrentIsAlwaysKeptEvenWhenRetentionIsZero() {
        let expired = PreUpgradeBackupPolicy.expiredDirectoryNames(
            existing: ["100-v1", "200-v2"],
            keeping: 0,
            current: "300-v3"
        )
        XCTAssertEqual(expired, ["100-v1", "200-v2"])
    }

    func testSortingUsesTimestampPrefixNotRawString() {
        // 9 位与 13 位时间戳混排时，按数值排序而不是字典序
        let existing = ["999-v1", "1000000000000-v2", "1000000000001-v3"]
        let expired = PreUpgradeBackupPolicy.expiredDirectoryNames(
            existing: existing,
            keeping: 2,
            current: "1000000000001-v3"
        )
        XCTAssertEqual(expired, ["999-v1"])
    }

    func testNonNumericNamesArePrunedFirst() {
        let existing = ["backup-a", "backup-b", "100-v1"]
        let expired = PreUpgradeBackupPolicy.expiredDirectoryNames(
            existing: existing,
            keeping: 1,
            current: "100-v1"
        )
        XCTAssertEqual(expired, ["backup-a", "backup-b"])
    }

    func testTimestampPrefixParsesLeadingDigits() {
        XCTAssertEqual(PreUpgradeBackupPolicy.timestampPrefix("1700000000000-v14"), 1_700_000_000_000)
        XCTAssertEqual(PreUpgradeBackupPolicy.timestampPrefix("backup-a"), 0)
        XCTAssertEqual(PreUpgradeBackupPolicy.timestampPrefix(""), 0)
    }
}
