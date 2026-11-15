import XCTest
import GRDB
import DFCore
@testable import DFData

/// D18：日记结构化字段触发外围人格提案，且必须经审批
final class DiaryPersonaProposalServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: DiaryPersonaProposalService!
    private var growth: PersonaGrowthService!
    private var personas: GRDBPersonaRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFDiaryPersona-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        personas = GRDBPersonaRepository(database: database)
        growth = PersonaGrowthService(database: database, now: { 4_000 })
        service = DiaryPersonaProposalService(database: database, personas: personas, growth: growth)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeEntry(
        id: String = "d1",
        date: String = "2026-11-15",
        title: String = "安静的下午",
        observation: String = "她今天主动说了自己有点累",
        relationshipChange: String = "开始愿意说心事了"
    ) -> DiaryEntry {
        DiaryEntry(
            id: id,
            entryDate: date,
            title: title,
            content: "今天一起待了一下午。",
            moodCode: "calm",
            source: "manual",
            generatedBy: nil,
            isUserEdited: true,
            memoryID: nil,
            sharedExperience: "一起看了会儿窗外",
            observation: observation,
            feeling: "很安心",
            relationshipChange: relationshipChange,
            relationshipChangeConfirmed: false,
            createdAt: 1,
            updatedAt: 1,
            deletedAt: nil
        )
    }

    func testObservationAndRelationshipChangeBecomePendingProposals() async throws {
        let outcome = try await service.propose(from: makeEntry())

        XCTAssertEqual(outcome.proposalIDs.count, 2)
        XCTAssertEqual(outcome.skippedExistingCount, 0)
        XCTAssertEqual(outcome.skippedPendingCount, 0)

        let proposals = try await growth.proposals()
        XCTAssertEqual(proposals.count, 2)
        XCTAssertTrue(proposals.allSatisfy { $0.status == "pending" }, "必须等待用户确认")
        let observation = try XCTUnwrap(proposals.first { $0.section == "日记观察" })
        XCTAssertEqual(observation.key, "观察·2026-11-15")
        XCTAssertEqual(observation.toValue, "她今天主动说了自己有点累")
        XCTAssertTrue(observation.evidenceJSON.contains("2026-11-15"))
        XCTAssertTrue(observation.evidenceJSON.contains("diary"))

        // 日记正文与感受不得直接变人格
        XCTAssertFalse(proposals.contains { $0.section == "感受" })
        XCTAssertFalse(proposals.contains { $0.toValue.contains("一起看了会儿窗外") })
    }

    func testEntryWithoutStructuredFieldsCreatesNothing() async throws {
        let entry = makeEntry(observation: "", relationshipChange: "")
        let outcome = try await service.propose(from: entry)

        XCTAssertTrue(outcome.proposalIDs.isEmpty)
        let personaCount = try await int("SELECT count(*) FROM personas")
        XCTAssertEqual(personaCount, 0, "没有可提炼内容时不得凭空创建人格")
    }

    func testRepeatedProposalSkipsPendingDuplicates() async throws {
        let entry = makeEntry()
        let first = try await service.propose(from: entry)
        XCTAssertEqual(first.proposalIDs.count, 2)

        let second = try await service.propose(from: entry)
        XCTAssertTrue(second.proposalIDs.isEmpty)
        XCTAssertEqual(second.skippedPendingCount, 2)

        let pending = try await growth.proposals().filter { $0.status == "pending" }
        XCTAssertEqual(pending.count, 2, "不得堆积重复提案")
    }

    func testExistingPersonaItemIsSkipped() async throws {
        let entry = makeEntry(relationshipChange: "")
        _ = try await service.propose(from: entry)
        let created = try await growth.proposals()
        let proposal = try XCTUnwrap(created.first)
        try await growth.approve(id: proposal.id)

        // 已写入外围人格后再次提炼，同内容不再产生提案
        let second = try await service.propose(from: entry)
        XCTAssertTrue(second.proposalIDs.isEmpty)
        XCTAssertEqual(second.skippedExistingCount, 1)
    }

    func testApprovalWritesOuterPersonaOnly() async throws {
        let outcome = try await service.propose(from: makeEntry())
        for id in outcome.proposalIDs {
            try await growth.approve(id: id)
        }

        let values = try await strings(
            "SELECT value FROM persona_items WHERE section IN ('日记观察', '关系变化') ORDER BY section"
        )
        XCTAssertEqual(values.count, 2)
        let coreCount = try await int("SELECT count(*) FROM persona_items WHERE section = '核心'")
        XCTAssertEqual(coreCount, 0, "核心人格不得被日记触发写入")
    }

    // MARK: - 查询辅助

    private func int(_ sql: String) async throws -> Int {
        try await database.dbQueue.read { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    private func strings(_ sql: String) async throws -> [String] {
        try await database.dbQueue.read { db in
            try String.fetchAll(db, sql: sql)
        }
    }
}
