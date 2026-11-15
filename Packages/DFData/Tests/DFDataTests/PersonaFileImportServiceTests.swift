import XCTest
import GRDB
import DFCore
@testable import DFData

/// D06：人格文件导入只生成待审批提案，不直接写人格
final class PersonaFileImportServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: PersonaFileImportService!
    private var growth: PersonaGrowthService!
    private var personas: GRDBPersonaRepository!

    private let markdown = """
    # 喜好

    - drink：奶茶
    - food：火锅
    """

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFPersonaImport-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        personas = GRDBPersonaRepository(database: database)
        growth = PersonaGrowthService(database: database, now: { 3_000 })
        service = PersonaFileImportService(database: database, personas: personas, growth: growth)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 种子

    private func seedCoreAndOuter() async throws {
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
        }
    }

    private func data(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - 预览

    func testPreviewClassifiesCreateUpdateAndUnchanged() async throws {
        try await seedCoreAndOuter()
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO persona_items
                (id, persona_id, section, key, value, confidence, weight, source, updated_at, tier, tier_status, tier_source, status)
            VALUES ('i-outer-food', 'p-outer', '喜好', 'food', '清淡', 1.0, 1.0, 'user', 1, 'outer', 'outer', 'seed', 'active')
            """)
        }

        let plan = try await service.preview(data: data(markdown), fileName: "persona.md")

        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertEqual(plan.unchangedCount, 1, "drink 内容一致，不产生提案")
        XCTAssertEqual(plan.updatedCount, 1, "food 内容不同，需要更新提案")
        XCTAssertEqual(plan.createdCount, 0)

        let drink = try XCTUnwrap(plan.candidates.first { $0.key == "drink" })
        XCTAssertEqual(drink.action, .unchanged)
        let food = try XCTUnwrap(plan.candidates.first { $0.key == "food" })
        XCTAssertEqual(food.action, .update)
        XCTAssertEqual(food.existingItemID, "i-outer-food")
        XCTAssertEqual(food.existingValue, "清淡")
        XCTAssertEqual(food.value, "火锅")
    }

    func testPreviewDoesNotWriteAnything() async throws {
        try await seedCoreAndOuter()
        _ = try await service.preview(data: data(markdown), fileName: "persona.md")

        let proposals = try await growth.proposals()
        XCTAssertTrue(proposals.isEmpty, "预览不得产生提案")
        let items = try await int("SELECT count(*) FROM persona_items WHERE persona_id = 'p-outer'")
        XCTAssertEqual(items, 1, "预览不得写入人格条目")
    }

    // MARK: - 导入

    func testApplyCreatesPendingProposalsWithoutTouchingPersona() async throws {
        try await seedCoreAndOuter()

        let result = try await service.apply(data: data(markdown), fileName: "persona.md")

        XCTAssertEqual(result.personaID, "p-outer")
        XCTAssertEqual(result.proposalIDs.count, 1, "只有新增的 food 需要提案")
        XCTAssertEqual(result.alreadyPendingCount, 0)
        XCTAssertEqual(result.plan.createdCount, 1)

        let pending = try await growth.proposals(personaID: "p-outer")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].status, "pending")
        XCTAssertEqual(pending[0].key, "food")
        XCTAssertEqual(pending[0].toValue, "火锅")
        XCTAssertTrue(pending[0].evidenceJSON.contains("persona.md"), "证据里必须保留来源文件名")

        let items = try await int("SELECT count(*) FROM persona_items WHERE persona_id = 'p-outer'")
        XCTAssertEqual(items, 1, "审批前不得写入新条目")
        let coreValue = try await string("SELECT value FROM persona_items WHERE id = 'i-core'")
        XCTAssertEqual(coreValue, "你是鲸鱼娘，不改。", "核心人格不受导入影响")
    }

    func testApprovedImportWritesOuterItem() async throws {
        try await seedCoreAndOuter()
        let result = try await service.apply(data: data(markdown), fileName: "persona.md")
        let proposalID = try XCTUnwrap(result.proposalIDs.first)

        try await growth.approve(id: proposalID)

        let value = try await string("SELECT value FROM persona_items WHERE persona_id = 'p-outer' AND key = 'food'")
        XCTAssertEqual(value, "火锅")
        let coreValue = try await string("SELECT value FROM persona_items WHERE id = 'i-core'")
        XCTAssertEqual(coreValue, "你是鲸鱼娘，不改。")
    }

    func testRepeatedImportSkipsAlreadyPendingProposal() async throws {
        try await seedCoreAndOuter()
        let first = try await service.apply(data: data(markdown), fileName: "persona.md")
        XCTAssertEqual(first.proposalIDs.count, 1)

        let second = try await service.apply(data: data(markdown), fileName: "persona.md")
        XCTAssertTrue(second.proposalIDs.isEmpty)
        XCTAssertEqual(second.alreadyPendingCount, 1)

        let pending = try await growth.proposals(personaID: "p-outer").filter { $0.status == "pending" }
        XCTAssertEqual(pending.count, 1, "不得堆积重复提案")
    }

    func testApplyCreatesOuterPersonaWhenMissing() async throws {
        let result = try await service.apply(data: data(markdown), fileName: "persona.md")

        XCTAssertEqual(result.proposalIDs.count, 2, "没有外围人格时全部按新增提案")
        let outerID = try await string("SELECT id FROM personas WHERE kind = 'outer'")
        XCTAssertEqual(result.personaID, outerID)

        let personaCount = try await int("SELECT count(*) FROM personas")
        XCTAssertEqual(personaCount, 1, "导入只创建外围人格，不得凭空创建核心人格")
        let growthEnabled = try await int("SELECT growth_enabled FROM personas WHERE kind = 'outer'")
        XCTAssertEqual(growthEnabled, 1, "外围人格必须允许自主成长")
        let versions = try await int("SELECT count(*) FROM persona_versions WHERE persona_id = '\(result.personaID)'")
        XCTAssertEqual(versions, 1, "创建人格必须留一条版本快照")
    }

    func testUnsupportedFormatThrows() async throws {
        do {
            _ = try await service.apply(data: data("a: b"), fileName: "persona.yaml")
            XCTFail("不支持的格式必须报错")
        } catch let error as PersonaParseError {
            XCTAssertEqual(error, .unsupportedFormat("yaml"))
        }
    }

    // MARK: - 查询辅助

    private func int(_ sql: String) async throws -> Int {
        try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: sql) ?? -1
        }
    }

    private func string(_ sql: String) async throws -> String {
        try await database.dbQueue.read { db in
            try String.fetchOne(db, sql: sql) ?? ""
        }
    }
}
