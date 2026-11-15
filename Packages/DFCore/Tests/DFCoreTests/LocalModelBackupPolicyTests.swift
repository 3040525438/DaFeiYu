import XCTest
@testable import DFCore

/// D61：本地模型独立备份的勾选与兼容性判定
final class LocalModelBackupPolicyTests: XCTestCase {
    private let checksum = String(repeating: "a", count: 64)

    private func model(
        id: String = "m1",
        name: String = "Qwen2.5 3B",
        format: String = "gguf",
        status: LocalModelStatus = .ready,
        sha256: String? = nil,
        byteSize: Int64 = 2_000,
        version: String = "1.0",
        sourceURL: String? = "https://example.com/model.gguf",
        quantization: String = "Q4_K_M",
        verified: Bool = false
    ) -> LocalModelRecord {
        LocalModelRecord(
            id: id,
            name: name,
            quantization: quantization,
            format: format,
            fileRelPath: "\(id).gguf",
            byteSize: byteSize,
            sha256: sha256 ?? checksum,
            sourceURL: sourceURL,
            version: version,
            status: status,
            downloadedBytes: status == .ready ? byteSize : 0,
            lastVerifiedAt: verified ? 1 : nil,
            createdAt: 1,
            updatedAt: 1
        )
    }

    // MARK: - 兼容性

    func testReadyGGUFWithChecksumIsCompatible() {
        let compatibility = LocalModelBackupPolicy.compatibility(model())
        XCTAssertEqual(compatibility, .compatible)
        XCTAssertTrue(compatibility.isCompatible)
        XCTAssertEqual(compatibility.text, "兼容")
    }

    func testFormatComparisonIsCaseInsensitive() {
        XCTAssertEqual(LocalModelBackupPolicy.compatibility(model(format: "GGUF")), .compatible)
    }

    func testUnsupportedFormatIsRejected() {
        let compatibility = LocalModelBackupPolicy.compatibility(model(format: "bin"))
        XCTAssertEqual(compatibility, .unsupportedFormat("bin"))
        XCTAssertFalse(compatibility.isCompatible)
    }

    func testNotReadyIsRejected() {
        XCTAssertEqual(
            LocalModelBackupPolicy.compatibility(model(status: .downloading)),
            .notDownloaded
        )
    }

    func testMissingChecksumIsRejected() {
        XCTAssertEqual(
            LocalModelBackupPolicy.compatibility(model(sha256: "abc")),
            .checksumMissing
        )
        XCTAssertEqual(
            LocalModelBackupPolicy.compatibility(model(sha256: String(repeating: "z", count: 64))),
            .checksumMissing
        )
    }

    func testChecksumValidation() {
        XCTAssertTrue(LocalModelBackupPolicy.isValidChecksum(checksum.uppercased()))
        XCTAssertTrue(LocalModelBackupPolicy.isValidChecksum("  \(checksum)  "))
        XCTAssertFalse(LocalModelBackupPolicy.isValidChecksum(nil))
        XCTAssertFalse(LocalModelBackupPolicy.isValidChecksum(""))
        XCTAssertFalse(LocalModelBackupPolicy.isValidChecksum(String(repeating: "a", count: 63)))
    }

    // MARK: - 计划

    func testSelectedCompatibleModelEntersPlan() {
        let plan = LocalModelBackupPolicy.plan(models: [model()], selectedIDs: ["m1"])
        XCTAssertEqual(plan.included.map(\.id), ["m1"])
        XCTAssertEqual(plan.totalBytes, 2_000)
        XCTAssertFalse(plan.isEmpty)
        let entry = plan.included[0]
        XCTAssertEqual(entry.version, "1.0")
        XCTAssertEqual(entry.sha256, checksum)
        XCTAssertEqual(entry.sourceURL, "https://example.com/model.gguf")
        XCTAssertEqual(entry.compatibility, .compatible)
        XCTAssertFalse(entry.isVerified)
    }

    func testUnselectedModelIsExcludedWithReason() {
        let plan = LocalModelBackupPolicy.plan(models: [model()], selectedIDs: [])
        XCTAssertTrue(plan.included.isEmpty)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.excluded.first?.reason, .notSelected)
    }

    func testUnavailableReasonsTakePriorityOverSelection() {
        let plan = LocalModelBackupPolicy.plan(
            models: [model(status: .notDownloaded)],
            selectedIDs: ["m1"]
        )
        XCTAssertEqual(plan.excluded.first?.reason, .notReady)
    }

    func testPlanSortedByName() {
        let plan = LocalModelBackupPolicy.plan(
            models: [
                model(id: "b", name: "B 模型"),
                model(id: "a", name: "A 模型")
            ],
            selectedIDs: ["a", "b"]
        )
        XCTAssertEqual(plan.included.map(\.name), ["A 模型", "B 模型"])
    }

    func testSizeLimitExcludesOverflow() {
        let plan = LocalModelBackupPolicy.plan(
            models: [
                model(id: "big", name: "A 大模型", byteSize: 900),
                model(id: "small", name: "B 小模型", byteSize: 100)
            ],
            selectedIDs: ["big", "small"],
            maxTotalBytes: 500
        )
        XCTAssertEqual(plan.included.map(\.id), ["small"])
        XCTAssertEqual(plan.totalBytes, 100)
        XCTAssertEqual(
            plan.excluded.first { $0.id == "big" }?.reason,
            .overSizeLimit
        )
    }

    func testChecksumStoredLowercase() {
        let plan = LocalModelBackupPolicy.plan(
            models: [model(sha256: checksum.uppercased())],
            selectedIDs: ["m1"]
        )
        XCTAssertEqual(plan.included.first?.sha256, checksum)
    }

    func testVerifiedFlagFollowsLastVerifiedAt() {
        let plan = LocalModelBackupPolicy.plan(
            models: [model(verified: true)],
            selectedIDs: ["m1"]
        )
        XCTAssertEqual(plan.included.first?.isVerified, true)
    }
}
