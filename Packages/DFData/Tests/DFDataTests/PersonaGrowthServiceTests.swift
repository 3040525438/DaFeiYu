import XCTest
import GRDB
import DFCore
@testable import DFData

/// 人格成长：提案审批、核心写保护、版本回退（W6 / P-05、P-11）
final class PersonaGrowthServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: PersonaGrowthService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFPersona-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        service = PersonaGrowthService(database: database, now: { 2_000 })
        try await seed()
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func seed() async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO personas (id, kind, name, is_locked, current_version, created_at, updated_at, fingerprint_scope, growth_enabled)
            VALUES ('p-core', 'core', '大肥鱼', 1, 1, 1, 1, 'core', 0)
            """)
            try db.execute(sql: """
            INSERT INTO personas (id, kind, name, is_locked, current_version, created_at, updated_at, fingerprint_scope, growth_enabled)
            VALUES ('p-outer', 'outer', '外围成长', 0, 1, 1, 1, 'core_outer', 1)
            """)
            try db.execute(sql: """
            INSERT INTO persona_items
                (id, persona_id, section, key, value, confidence, weight, source, updated_at, tier, tier_status, tier_source, status)
            VALUES ('i-core', 'p-core', '核心', 'system_prompt', '你是鲸鱼娘，不改。', 1.0, 1.0, 'user', 1, 'core', 'core', 'seed', 'active')
            """)
            try db.execute(sql: """
            INSERT INTO persona_items
                (id, persona_id, section, key, value, confidence, weight, source, updated_at, tier, tier_status, tier_source, status)
            VALUES ('i-outer', 'p-outer', '喜好', 'drink', '奶茶', 1.0, 1.0, 'user', 1, 'outer', 'outer', 'seed', 'active')
            """)
            try db.execute(
                sql: """
                INSERT INTO persona_versions (id, persona_id, version, snapshot_json, change_reason, changed_by, created_at)
                VALUES ('v-core-1', 'p-core', 1, ?, '初始', 'user', 1)
                """,
                arguments: [Self.snapshot(name: "大肥鱼", items: [("核心", "system_prompt", "你是鲸鱼娘，不改。")])]
            )
            try db.execute(
                sql: """
                INSERT INTO persona_versions (id, persona_id, version, snapshot_json, change_reason, changed_by, created_at)
                VALUES ('v-outer-1', 'p-outer', 1, ?, '初始', 'user', 1)
                """,
                arguments: [Self.snapshot(name: "外围成长", items: [("喜好", "drink", "奶茶")])]
            )
        }
    }

    private static func snapshot(name: String, items: [(String, String, String)]) -> String {
        let payload: [String: Any] = [
            "name": name,
            "items": items.map { ["section": $0.0, "key": $0.1, "value": $0.2] }
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func outerDraft(to value: String, itemID: String? = "i-outer") -> PersonaGrowthDraft {
        PersonaGrowthDraft(
            personaID: "p-outer",
            itemID: itemID,
            section: "喜好",
            key: "drink",
            fromValue: "奶茶",
            toValue: value,
            reason: "对方多次提到喜欢咖啡",
            evidenceJSON: "[\"m-1\",\"m-2\"]"
        )
    }

    // MARK: - 核心写保护

    func testCorePersonaCannotBeChangedByProposal() async throws {
        let draft = PersonaGrowthDraft(
            personaID: "p-core",
            itemID: "i-core",
            section: "核心",
            key: "system_prompt",
            toValue: "改写核心",
            reason: "模型想改"
        )
        do {
            _ = try await service.propose(draft)
            XCTFail("核心人格必须拒绝 AI 提案")
        } catch let error as PersonaGrowthError {
            XCTAssertEqual(error, .coreProtected("大肥鱼"))
        }

        let proposals = try await service.proposals()
        XCTAssertTrue(proposals.isEmpty)
        let value = try await string("SELECT value FROM persona_items WHERE id = 'i-core'")
        XCTAssertEqual(value, "你是鲸鱼娘，不改。")
    }

    // MARK: - 审批

    func testApproveUpdatesItemAndWritesVersion() async throws {
        let beforeCore = try await service.fingerprint(personaID: "p-outer", scope: .core)
        let beforeCoreOuter = try await service.fingerprint(personaID: "p-outer", scope: .coreOuter)

        let proposal = try await service.propose(outerDraft(to: "咖啡"))
        XCTAssertEqual(proposal.status, "pending")

        let approved = try await service.approve(id: proposal.id)
        XCTAssertEqual(approved.status, "approved")

        let value = try await string("SELECT value FROM persona_items WHERE id = 'i-outer'")
        XCTAssertEqual(value, "咖啡")
        let version = try await int("SELECT current_version FROM personas WHERE id = 'p-outer'")
        XCTAssertEqual(version, 2)

        let versions = try await service.versions(personaID: "p-outer")
        XCTAssertEqual(versions.first?.version, 2)
        XCTAssertTrue(versions.first?.snapshotJSON.contains("咖啡") == true)

        let afterCore = try await service.fingerprint(personaID: "p-outer", scope: .core)
        let afterCoreOuter = try await service.fingerprint(personaID: "p-outer", scope: .coreOuter)
        XCTAssertEqual(afterCore, beforeCore, "只改外围不应影响核心指纹")
        XCTAssertNotEqual(afterCoreOuter, beforeCoreOuter)

        let stored = try await service.proposals(personaID: "p-outer")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.status, "approved")
    }

    func testApproveNewItemInsertsIt() async throws {
        let proposal = try await service.propose(
            PersonaGrowthDraft(
                personaID: "p-outer",
                section: "喜好",
                key: "food",
                toValue: "火锅",
                reason: "新出现的稳定偏好"
            )
        )
        _ = try await service.approve(id: proposal.id)

        let count = try await int(
            "SELECT count(*) FROM persona_items WHERE persona_id = 'p-outer' AND key = 'food'"
        )
        XCTAssertEqual(count, 1)
        let version = try await int("SELECT current_version FROM personas WHERE id = 'p-outer'")
        XCTAssertEqual(version, 2)
    }

    func testRejectKeepsItemUntouched() async throws {
        let proposal = try await service.propose(outerDraft(to: "咖啡"))
        try await service.reject(id: proposal.id, note: "证据不足")

        let value = try await string("SELECT value FROM persona_items WHERE id = 'i-outer'")
        XCTAssertEqual(value, "奶茶")
        let version = try await int("SELECT current_version FROM personas WHERE id = 'p-outer'")
        XCTAssertEqual(version, 1)

        let stored = try await service.proposals(personaID: "p-outer")
        XCTAssertEqual(stored.first?.status, "rejected")
        XCTAssertEqual(stored.first?.resolutionNote, "证据不足")
    }

    func testDoubleApproveFails() async throws {
        let proposal = try await service.propose(outerDraft(to: "咖啡"))
        _ = try await service.approve(id: proposal.id)

        do {
            _ = try await service.approve(id: proposal.id)
            XCTFail("已处理提案不能再次审批")
        } catch let error as PersonaGrowthError {
            XCTAssertEqual(error, .proposalResolved("approved"))
        }
    }

    func testMissingItemFails() async throws {
        let proposal = try await service.propose(outerDraft(to: "咖啡", itemID: "not-exist"))
        do {
            _ = try await service.approve(id: proposal.id)
            XCTFail("目标条目不存在时应失败")
        } catch let error as PersonaGrowthError {
            XCTAssertEqual(error, .itemNotFound("not-exist"))
        }
        let value = try await string("SELECT value FROM persona_items WHERE id = 'i-outer'")
        XCTAssertEqual(value, "奶茶")
    }

    // MARK: - 版本回退

    func testRestoreCreatesNewVersionAndRevertsItems() async throws {
        let proposal = try await service.propose(outerDraft(to: "咖啡"))
        _ = try await service.approve(id: proposal.id)
        let approvedValue = try await string("SELECT value FROM persona_items WHERE id = 'i-outer'")
        XCTAssertEqual(approvedValue, "咖啡")

        let restored = try await service.restore(personaID: "p-outer", version: 1)
        XCTAssertEqual(restored.version, 3)
        XCTAssertEqual(restored.changedBy, "user")
        XCTAssertTrue(restored.changeReason.contains("回退到版本 1"))

        let value = try await string("SELECT value FROM persona_items WHERE id = 'i-outer'")
        XCTAssertEqual(value, "奶茶")
        let version = try await int("SELECT current_version FROM personas WHERE id = 'p-outer'")
        XCTAssertEqual(version, 3)

        // 历史版本不删除
        let versions = try await service.versions(personaID: "p-outer")
        XCTAssertEqual(versions.count, 3)
    }

    func testRestoreCorePersonaIsAllowedAsUserAction() async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE persona_items SET value = '被手动改坏了' WHERE id = 'i-core'"
            )
        }
        let restored = try await service.restore(personaID: "p-core", version: 1)
        XCTAssertEqual(restored.version, 2)
        let value = try await string("SELECT value FROM persona_items WHERE persona_id = 'p-core' AND key = 'system_prompt'")
        XCTAssertEqual(value, "你是鲸鱼娘，不改。")
    }

    func testRestoreMissingVersionFails() async throws {
        do {
            _ = try await service.restore(personaID: "p-outer", version: 99)
            XCTFail("不存在的版本应失败")
        } catch let error as PersonaGrowthError {
            XCTAssertEqual(error, .versionNotFound(personaID: "p-outer", version: 99))
        }
    }

    // MARK: - 工具

    private func string(_ sql: String) async throws -> String? {
        try await database.dbQueue.read { db in try String.fetchOne(db, sql: sql) }
    }

    private func int(_ sql: String) async throws -> Int? {
        try await database.dbQueue.read { db in try Int.fetchOne(db, sql: sql) }
    }
}
