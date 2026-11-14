import XCTest
import GRDB
import DFCore
@testable import DFData

/// 关系档案：阶段提案 / 用户确认 / 历史留痕 / 共同经历（W6C / 决策 31、A-14）
final class RelationshipServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: RelationshipService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFRelationship-\(UUID().uuidString)", isDirectory: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        service = RelationshipService(database: database, now: { 2_000 })
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO memories
                (id, type, title, content, importance, salience, confidence, status, first_seen_at)
            VALUES ('m-1', 'episode', '第一次一起看海', '真实发生过的经历', 'normal', 0.5, 0.9, 'active', 1)
            """)
        }
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - 不凭空生成

    func testEmptyProfileDoesNotCreateRow() async throws {
        let profile = try await service.profile()
        XCTAssertEqual(profile.stage, .unset)
        XCTAssertEqual(profile.closeness, 0.5, accuracy: 0.0001)
        XCTAssertNil(profile.confirmedAt)

        let rows = try await int("SELECT count(*) FROM relationship_profile")
        XCTAssertEqual(rows, 0, "读取档案不得创建关系记录")
    }

    func testProposalDoesNotChangeStageUntilConfirmed() async throws {
        let change = try await service.proposeStage(
            to: .familiar,
            reason: "连续 30 天主动聊天",
            evidenceJSON: "[\"m-1\"]",
            memoryID: "m-1"
        )
        XCTAssertEqual(change.status, .pending)
        XCTAssertEqual(change.fromStage, .unset)
        XCTAssertEqual(change.decidedBy, "ai")

        let profile = try await service.profile()
        XCTAssertEqual(profile.stage, .unset, "未确认的提案不得改变档案阶段")
        let profileRows = try await int("SELECT count(*) FROM relationship_profile")
        let changeRows = try await int("SELECT count(*) FROM relationship_stage_history")
        XCTAssertEqual(profileRows, 0)
        XCTAssertEqual(changeRows, 1)
    }

    // MARK: - 用户确认

    func testConfirmAppliesStageAndStamps() async throws {
        let change = try await service.proposeStage(
            to: .familiar,
            reason: "连续 30 天主动聊天",
            evidenceJSON: "[\"m-1\"]"
        )
        let approved = try await service.confirmStageChange(id: change.id)
        XCTAssertEqual(approved.status, .approved)
        XCTAssertEqual(approved.resolvedAt, 2_000)

        let profile = try await service.profile()
        XCTAssertEqual(profile.stage, .familiar)
        XCTAssertEqual(profile.stageSince, 2_000)
        XCTAssertEqual(profile.confirmedBy, "user")
        XCTAssertEqual(profile.confirmedAt, 2_000)

        let history = try await service.stageHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.status, .approved)

        // 已确认记录不得被删除（可回顾）
        let rows = try await int("SELECT count(*) FROM relationship_stage_history")
        XCTAssertEqual(rows, 1)
    }

    func testAICannotConfirm() async throws {
        let change = try await service.proposeStage(to: .familiar, reason: "模型自荐")
        do {
            _ = try await service.confirmStageChange(id: change.id, by: "ai")
            XCTFail("AI 不得确认关系阶段")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .confirmationRequiresUser("ai"))
        }
        let profile = try await service.profile()
        XCTAssertEqual(profile.stage, .unset)
    }

    func testDoubleConfirmFails() async throws {
        let change = try await service.proposeStage(to: .familiar, reason: "证据充分")
        _ = try await service.confirmStageChange(id: change.id)
        do {
            _ = try await service.confirmStageChange(id: change.id)
            XCTFail("已确认的提案不能再次确认")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .changeResolved("approved"))
        }
    }

    func testStaleProposalAfterAnotherConfirmationFails() async throws {
        let first = try await service.proposeStage(to: .familiar, reason: "第一份证据")
        let second = try await service.proposeStage(to: .close, reason: "第二份证据")
        _ = try await service.confirmStageChange(id: first.id)

        do {
            _ = try await service.confirmStageChange(id: second.id)
            XCTFail("基于过期阶段的提案必须被拒绝")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .staleChange(from: .unset, current: .familiar))
        }
        let profile = try await service.profile()
        XCTAssertEqual(profile.stage, .familiar)

        // 旧提案仍在历史中，状态仍为 pending，可被驳回
        let history = try await service.stageHistory()
        XCTAssertEqual(history.first(where: { $0.id == second.id })?.status, .pending)
    }

    func testRejectKeepsStageAndHistory() async throws {
        let change = try await service.proposeStage(to: .close, reason: "证据不足的推断")
        try await service.rejectStageChange(id: change.id)

        let profile = try await service.profile()
        XCTAssertEqual(profile.stage, .unset)

        let history = try await service.stageHistory()
        XCTAssertEqual(history.first?.status, .rejected)
        XCTAssertEqual(history.first?.resolvedAt, 2_000)
        let rows = try await int("SELECT count(*) FROM relationship_stage_history")
        XCTAssertEqual(rows, 1)
    }

    func testRejectRequiresPendingAndUser() async throws {
        let change = try await service.proposeStage(to: .close, reason: "推断")
        do {
            try await service.rejectStageChange(id: change.id, by: "ai")
            XCTFail("AI 不得驳回关系阶段")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .confirmationRequiresUser("ai"))
        }
        _ = try await service.confirmStageChange(id: change.id)
        do {
            try await service.rejectStageChange(id: change.id)
            XCTFail("已确认的提案不能驳回")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .changeResolved("approved"))
        }
    }

    // MARK: - 提案校验

    func testInvalidProposalsAreRejected() async throws {
        do {
            _ = try await service.proposeStage(to: .unset, reason: "非法目标")
            XCTFail("unset 不能作为提案目标")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .invalidStage("unset"))
        }

        _ = try await service.proposeStage(to: .familiar, reason: "先升到熟悉")
        let first = try await service.stageHistory().first
        _ = try await service.confirmStageChange(id: first!.id)

        do {
            _ = try await service.proposeStage(to: .familiar, reason: "重复阶段")
            XCTFail("同一阶段不应重复提案")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .sameStage("familiar"))
        }

        do {
            _ = try await service.proposeStage(to: .close, reason: "   ")
            XCTFail("必须写明理由")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .reasonRequired)
        }

        do {
            _ = try await service.proposeStage(to: .close, reason: "理由", evidenceJSON: "不是数组")
            XCTFail("证据必须是 JSON 数组")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .evidenceInvalid)
        }

        do {
            _ = try await service.proposeStage(to: .close, reason: "理由", memoryID: "m-missing")
            XCTFail("关联记忆必须存在")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .memoryNotFound("m-missing"))
        }
    }

    func testDuplicatePendingProposalIsIdempotent() async throws {
        let first = try await service.proposeStage(to: .familiar, reason: "同一目标")
        let second = try await service.proposeStage(to: .familiar, reason: "同一目标")
        XCTAssertEqual(first.id, second.id)
        let rows = try await int("SELECT count(*) FROM relationship_stage_history")
        XCTAssertEqual(rows, 1)
    }

    // MARK: - 档案写入

    func testUpdateProfileWritesOnlyGivenFields() async throws {
        let created = try await service.updateProfile(partnerName: "小鱼", closeness: 0.7)
        XCTAssertEqual(created.stage, .unset, "写昵称不得凭空确认阶段")
        XCTAssertEqual(created.partnerName, "小鱼")
        XCTAssertEqual(created.closeness, 0.7, accuracy: 0.0001)

        let updated = try await service.updateProfile(summary: "一起看海的那天")
        XCTAssertEqual(updated.partnerName, "小鱼")
        XCTAssertEqual(updated.summary, "一起看海的那天")
        let rows = try await int("SELECT count(*) FROM relationship_profile")
        XCTAssertEqual(rows, 1)

        do {
            _ = try await service.updateProfile(closeness: 1.5)
            XCTFail("亲密度必须在 0–1 之间")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .invalidCloseness(1.5))
        }

        do {
            _ = try await service.updateProfile(summary: "AI 想改档案", by: "ai")
            XCTFail("AI 不得直接改写关系档案")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .invalidDecisionMaker("ai"))
        }

        do {
            _ = try await service.updateProfile()
            XCTFail("空更新应失败")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .emptyUpdate)
        }
    }

    // MARK: - 共同经历与重要转折

    func testAddMilestoneAndOrdering() async throws {
        let older = try await service.addMilestone(
            RelationshipMilestoneDraft(
                kind: .sharedExperience,
                title: "第一次一起看海",
                summary: "那天风很大",
                occurredAt: 1_000,
                timePrecision: .day,
                memoryID: "m-1",
                sourceKind: .realInteraction
            )
        )
        _ = try await service.addMilestone(
            RelationshipMilestoneDraft(
                kind: .turningPoint,
                title: "决定一起养猫",
                occurredAt: 3_000,
                timePrecision: .month,
                importance: "high",
                sourceKind: .userConfirmed
            )
        )
        XCTAssertEqual(older.status, "active")
        XCTAssertEqual(older.sourceKind, .realInteraction)

        let list = try await service.milestones()
        XCTAssertEqual(list.map(\.title), ["决定一起养猫", "第一次一起看海"])
        XCTAssertEqual(list.last?.memoryID, "m-1")
    }

    func testMilestoneValidation() async throws {
        do {
            _ = try await service.addMilestone(
                RelationshipMilestoneDraft(kind: .other, title: "  ", occurredAt: 1_000)
            )
            XCTFail("标题不能为空")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .invalidMilestone("标题不能为空"))
        }

        do {
            _ = try await service.addMilestone(
                RelationshipMilestoneDraft(kind: .other, title: "时间缺失", occurredAt: 0)
            )
            XCTFail("发生时间不合法")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .invalidMilestone("发生时间不合法"))
        }

        do {
            _ = try await service.addMilestone(
                RelationshipMilestoneDraft(kind: .other, title: "重要度错误", occurredAt: 1_000, importance: "urgent")
            )
            XCTFail("重要度必须受控")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .invalidMilestone("重要度只能是 low / normal / high"))
        }

        do {
            _ = try await service.addMilestone(
                RelationshipMilestoneDraft(kind: .other, title: "悬空记忆", occurredAt: 1_000, memoryID: "m-missing")
            )
            XCTFail("关联记忆必须存在")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .memoryNotFound("m-missing"))
        }

        do {
            _ = try await service.addMilestone(
                RelationshipMilestoneDraft(kind: .other, title: "悬空经历", occurredAt: 1_000, episodeID: "e-missing")
            )
            XCTFail("关联经历必须存在")
        } catch let error as RelationshipError {
            XCTAssertEqual(error, .episodeNotFound("e-missing"))
        }

        let rows = try await int("SELECT count(*) FROM relationship_milestones")
        XCTAssertEqual(rows, 0)
    }

    // MARK: - 工具

    private func int(_ sql: String) async throws -> Int? {
        try await database.dbQueue.read { db in try Int.fetchOne(db, sql: sql) }
    }
}
