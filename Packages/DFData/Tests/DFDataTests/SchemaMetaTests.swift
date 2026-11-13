import XCTest
import GRDB
import DFCore
@testable import DFData

/// 迁移台账摘要与前缀校验
final class SchemaMetaTests: XCTestCase {
    func testDigestIsStableForSamePrefix() {
        let prefix = ["v1_phase1", "v2_memory"]
        let first = MigrationLedger.digest(prefix: prefix)
        let second = MigrationLedger.digest(prefix: prefix)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(first, first.lowercased())
        XCTAssertEqual(first, SHA256.hash("migrations-v1\nv1_phase1\nv2_memory"))
    }

    func testDigestDiffersBetweenPrefixes() {
        XCTAssertNotEqual(
            MigrationLedger.digest(prefix: ["v1_phase1"]),
            MigrationLedger.digest(prefix: ["v1_phase1", "v2_memory"])
        )
    }

    func testValidatedPrefixAcceptsCanonicalPrefix() throws {
        XCTAssertEqual(try MigrationLedger.validatedPrefix(applied: ["v1_phase1"]), ["v1_phase1"])
        // 顺序不同但集合正确，按规范顺序返回
        XCTAssertEqual(
            try MigrationLedger.validatedPrefix(applied: ["v2_memory", "v1_phase1"]),
            ["v1_phase1", "v2_memory"]
        )
    }

    func testValidatedPrefixRejectsGap() {
        XCTAssertThrowsError(try MigrationLedger.validatedPrefix(applied: ["v1_phase1", "v3_chat"])) { error in
            guard case MigrationOrderError.notPrefix = error else {
                XCTFail("应抛出 notPrefix，实际：\(error)")
                return
            }
        }
    }

    func testValidatedPrefixRejectsUnknownIdentifier() {
        XCTAssertThrowsError(try MigrationLedger.validatedPrefix(applied: ["v1_phase1", "vX_test"])) { error in
            guard case MigrationOrderError.unknownIdentifier = error else {
                XCTFail("应抛出 unknownIdentifier，实际：\(error)")
                return
            }
        }
    }

    func testExpectedPrefixIncludingRejectsWrongCurrent() {
        XCTAssertThrowsError(
            try SchemaMeta.expectedPrefixIncluding(current: .v3_chat, appliedBefore: ["v1_phase1"])
        ) { error in
            guard case MigrationOrderError.unexpectedCurrent = error else {
                XCTFail("应抛出 unexpectedCurrent，实际：\(error)")
                return
            }
        }
    }

    func testExpectedPrefixIncludingAcceptsNextInOrder() throws {
        let prefix = try SchemaMeta.expectedPrefixIncluding(current: .v2_memory, appliedBefore: ["v1_phase1"])
        XCTAssertEqual(prefix, ["v1_phase1", "v2_memory"])
    }

    func testVerifyDetectsVersionMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFMeta-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try AppDatabase(paths: DatabasePaths(root: root))
        XCTAssertNoThrow(try database.dbQueue.read { try SchemaMeta.verify($0) })

        try database.dbQueue.write { db in
            try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: "v1_phase1", at: 1)
        }

        XCTAssertThrowsError(try database.dbQueue.read { try SchemaMeta.verify($0) }) { error in
            guard case SchemaMetaError.versionMismatch = error else {
                XCTFail("应抛出 versionMismatch，实际：\(error)")
                return
            }
        }
    }
}
