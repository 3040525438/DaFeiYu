import XCTest
@testable import DFCore

/// W10-3：诊断包脱敏与存储分类
final class DiagnosticsTests: XCTestCase {
    func testRedactMasksSecretsAndPersonalData() {
        let raw = """
        api_key=sk-abcdef1234567890
        Authorization: Bearer eyJhbGciOiJIUzI1NiJ9
        联系邮箱 someone@example.com，手机 13812345678
        路径 C:\\Users\\alice\\Documents 与 /Users/bob/work
        哈希 0123456789abcdef0123456789abcdef
        """
        let redacted = DiagnosticRedactor.redact(raw)
        XCTAssertFalse(redacted.contains("sk-abcdef1234567890"))
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertFalse(redacted.contains("someone@example.com"))
        XCTAssertFalse(redacted.contains("13812345678"))
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertFalse(redacted.contains("bob"))
        XCTAssertFalse(redacted.contains("0123456789abcdef0123456789abcdef"))
    }

    func testRedactKeepsNormalText() {
        let text = "架构版本 v11_local_models，记录 42 条，健康检查通过。"
        XCTAssertEqual(DiagnosticRedactor.redact(text), text)
    }

    func testHumanReadableFormatting() {
        XCTAssertEqual(StorageUsage.humanReadable(512), "512 B")
        XCTAssertEqual(StorageUsage.humanReadable(2048), "2.0 KB")
        XCTAssertEqual(StorageUsage.humanReadable(3 * 1024 * 1024), "3.0 MB")
    }

    func testStorageTotalSumsItems() {
        let usage = StorageUsage(items: [
            StorageUsageItem(key: "db", title: "数据库", bytes: 1024),
            StorageUsageItem(key: "attachments", title: "附件", bytes: 2048)
        ])
        XCTAssertEqual(usage.totalBytes, 3072)
    }

    func testLowSpaceFlag() {
        let base = DiagnosticReport(
            appVersion: "0.1.0",
            schemaVersion: "v11_local_models",
            platform: "iOS",
            generatedAt: 1_700_000_000_000,
            counts: ["messages": 10],
            storage: StorageUsage(items: []),
            healthy: true,
            healthNotes: [],
            freeBytes: 100 * 1024 * 1024
        )
        XCTAssertTrue(base.isLowOnSpace)

        var roomy = base
        roomy.freeBytes = 5 * 1024 * 1024 * 1024
        XCTAssertFalse(roomy.isLowOnSpace)
    }

    func testMarkdownContainsSectionsAndNoSecrets() {
        let report = DiagnosticReport(
            appVersion: "0.1.0",
            schemaVersion: "v11_local_models",
            platform: "iOS",
            generatedAt: 1_700_000_000_000,
            counts: ["messages": 10, "memories": 3],
            storage: StorageUsage(items: [StorageUsageItem(key: "db", title: "数据库", bytes: 4096)]),
            healthy: false,
            healthNotes: ["密钥 sk-abcdef1234567890 无效"],
            freeBytes: 800 * 1024 * 1024
        )
        let markdown = DiagnosticExporter.markdown(report)
        XCTAssertTrue(markdown.contains("## 记录计数"))
        XCTAssertTrue(markdown.contains("## 存储占用"))
        XCTAssertTrue(markdown.contains("健康检查：异常"))
        XCTAssertFalse(markdown.contains("sk-abcdef1234567890"), "健康提示里的密钥也要脱敏")
    }

    func testFileNameUsesTimestamp() {
        XCTAssertEqual(DiagnosticExporter.fileName(at: 1234), "dafeiyu-diagnostics-1234.md")
    }
}
