import Foundation
import GRDB
import DFCore

/// 关系档案：阶段提案 → 用户确认 → 落档案 + 留痕；共同经历与重要转折。
///
/// 硬规则（决策 31 / A-14 / W6-9）：
/// - 关系数据**不凭空生成**：没有用户写入时档案不落库，读取返回内存默认值（阶段 `unset`）；
/// - AI 只能**提案**阶段变化，`confirmStageChange` 只接受 `user`，其余决策方一律拒绝；
/// - 每次确认/驳回都保留历史行，不删除、不改写旧记录；
/// - 提案创建后档案阶段若已被改动，旧提案确认时报错（防止基于过期证据改阶段）；
/// - 里程碑必须写明来源，模型推断不得写成"真实互动"。
public final class RelationshipService: @unchecked Sendable {
    /// 单份关系的主档案 ID
    public static let primaryProfileID = "primary"

    private let database: AppDatabase
    private let now: @Sendable () -> Int64

    public init(database: AppDatabase, now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }) {
        self.database = database
        self.now = now
    }

    // MARK: - 读取

    /// 当前关系档案；未落库时返回默认值（阶段 `unset`），**不会**创建行。
    public func profile() async throws -> RelationshipProfile {
        try await database.dbQueue.read { db in
            try self.loadProfile(db)
        }
    }

    /// 阶段变更历史（新 → 旧），包含 pending / approved / rejected 全部记录。
    public func stageHistory(limit: Int = 100) async throws -> [RelationshipStageChange] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, from_stage, to_stage, reason, evidence_json, decided_by,
                       status, memory_id, created_at, resolved_at
                  FROM relationship_stage_history
                 ORDER BY created_at DESC, id DESC
                 LIMIT ?
                """,
                arguments: [max(1, limit)]
            )
            return rows.map(Self.decodeChange)
        }
    }

    /// 共同经历与重要转折（时间新 → 旧）
    public func milestones(limit: Int = 200) async throws -> [RelationshipMilestone] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, kind, title, summary, occurred_at, time_precision, importance,
                       memory_id, episode_id, source_kind, status, created_at, updated_at
                  FROM relationship_milestones
                 ORDER BY occurred_at DESC, created_at DESC
                 LIMIT ?
                """,
                arguments: [max(1, limit)]
            )
            return rows.map(Self.decodeMilestone)
        }
    }

    // MARK: - 档案（用户显式写入）

    /// 更新昵称 / 摘要 / 亲密度。只有用户能写，且只改传入的字段。
    @discardableResult
    public func updateProfile(
        partnerName: String? = nil,
        summary: String? = nil,
        closeness: Double? = nil,
        by actor: String = "user"
    ) async throws -> RelationshipProfile {
        try await database.write { db in
            guard actor == "user" else {
                throw RelationshipError.invalidDecisionMaker(actor)
            }
            guard partnerName != nil || summary != nil || closeness != nil else {
                throw RelationshipError.emptyUpdate
            }
            if let closeness, !(0...1).contains(closeness) {
                throw RelationshipError.invalidCloseness(closeness)
            }
            let name = partnerName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, name.isEmpty {
                throw RelationshipError.invalidPartnerName
            }

            let at = self.now()
            var current = try self.loadProfileRow(db)
            if let name { current.partnerName = name }
            if let summary { current.summary = summary }
            if let closeness { current.closeness = closeness }
            current.updatedAt = at

            if current.exists {
                try db.execute(
                    sql: """
                    UPDATE relationship_profile
                       SET partner_name = ?, summary = ?, closeness = ?, updated_at = ?
                     WHERE id = ?
                    """,
                    arguments: [current.partnerName, current.summary, current.closeness, at, Self.primaryProfileID]
                )
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO relationship_profile
                        (id, partner_name, stage, stage_since, closeness, summary,
                         evidence_json, confirmed_by, confirmed_at, updated_at)
                    VALUES (?, ?, 'unset', NULL, ?, ?, '[]', NULL, NULL, ?)
                    """,
                    arguments: [Self.primaryProfileID, current.partnerName, current.closeness, current.summary, at]
                )
            }
            return try self.loadProfile(db)
        }
    }

    // MARK: - 阶段提案

    /// 提出阶段变更（AI 或用户均可提案，但都必须经过用户确认才生效）。
    /// 同一目标阶段的重复提案幂等：返回已有的 pending 记录。
    @discardableResult
    public func proposeStage(
        to stage: RelationshipStage,
        reason: String,
        evidenceJSON: String = "[]",
        memoryID: String? = nil,
        decidedBy: String = "ai"
    ) async throws -> RelationshipStageChange {
        try await database.write { db in
            guard stage != .unset else {
                throw RelationshipError.invalidStage(stage.rawValue)
            }
            guard decidedBy == "ai" || decidedBy == "user" else {
                throw RelationshipError.invalidDecisionMaker(decidedBy)
            }
            let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedReason.isEmpty else {
                throw RelationshipError.reasonRequired
            }
            guard Self.isJSONArray(evidenceJSON) else {
                throw RelationshipError.evidenceInvalid
            }
            if let memoryID = memoryID {
                guard try self.exists(db, table: "memories", id: memoryID) else {
                    throw RelationshipError.memoryNotFound(memoryID)
                }
            }

            let current = try self.loadProfile(db)
            guard stage != current.stage else {
                throw RelationshipError.sameStage(stage.rawValue)
            }

            if let pending = try Row.fetchOne(
                db,
                sql: """
                SELECT id, from_stage, to_stage, reason, evidence_json, decided_by,
                       status, memory_id, created_at, resolved_at
                  FROM relationship_stage_history
                 WHERE status = 'pending' AND to_stage = ?
                 ORDER BY created_at DESC
                 LIMIT 1
                """,
                arguments: [stage.rawValue]
            ) {
                return Self.decodeChange(pending)
            }

            let at = self.now()
            let id = UUID().uuidString
            let fromStage: String? = current.stage == .unset ? nil : current.stage.rawValue
            try db.execute(
                sql: """
                INSERT INTO relationship_stage_history
                    (id, from_stage, to_stage, reason, evidence_json, decided_by,
                     status, memory_id, created_at, resolved_at)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, NULL)
                """,
                arguments: [
                    id,
                    fromStage,
                    stage.rawValue,
                    trimmedReason,
                    evidenceJSON,
                    decidedBy,
                    memoryID,
                    at
                ]
            )
            return RelationshipStageChange(
                id: id,
                fromStage: current.stage,
                toStage: stage,
                reason: trimmedReason,
                evidenceJSON: evidenceJSON,
                decidedBy: decidedBy,
                status: .pending,
                memoryID: memoryID,
                createdAt: at,
                resolvedAt: nil
            )
        }
    }

    /// 用户确认阶段变更：落档案（stage / stage_since / confirmed_by / confirmed_at）。
    @discardableResult
    public func confirmStageChange(id: String, by actor: String = "user") async throws -> RelationshipStageChange {
        try await database.write { db in
            guard actor == "user" else {
                throw RelationshipError.confirmationRequiresUser(actor)
            }
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, from_stage, to_stage, reason, evidence_json, decided_by,
                       status, memory_id, created_at, resolved_at
                  FROM relationship_stage_history
                 WHERE id = ?
                """,
                arguments: [id]
            ) else {
                throw RelationshipError.changeNotFound(id)
            }
            let change = Self.decodeChange(row)
            guard change.status == .pending else {
                throw RelationshipError.changeResolved(change.status.rawValue)
            }

            let current = try self.loadProfile(db)
            guard current.stage == change.fromStage else {
                throw RelationshipError.staleChange(from: change.fromStage, current: current.stage)
            }

            let at = self.now()
            let profileExists = try self.profileRowExists(db)
            if current.stage == .unset && !profileExists {
                try db.execute(
                    sql: """
                    INSERT INTO relationship_profile
                        (id, partner_name, stage, stage_since, closeness, summary,
                         evidence_json, confirmed_by, confirmed_at, updated_at)
                    VALUES (?, '', ?, ?, 0.5, '', '[]', 'user', ?, ?)
                    """,
                    arguments: [Self.primaryProfileID, change.toStage.rawValue, at, at, at]
                )
            } else {
                try db.execute(
                    sql: """
                    UPDATE relationship_profile
                       SET stage = ?, stage_since = ?, confirmed_by = 'user',
                           confirmed_at = ?, updated_at = ?
                     WHERE id = ?
                    """,
                    arguments: [change.toStage.rawValue, at, at, at, Self.primaryProfileID]
                )
            }

            try db.execute(
                sql: """
                UPDATE relationship_stage_history
                   SET status = 'approved', resolved_at = ?
                 WHERE id = ?
                """,
                arguments: [at, id]
            )

            var confirmed = change
            confirmed.status = .approved
            confirmed.resolvedAt = at
            return confirmed
        }
    }

    /// 用户驳回阶段变更：阶段不变，历史保留。
    public func rejectStageChange(id: String, by actor: String = "user") async throws {
        try await database.write { db in
            guard actor == "user" else {
                throw RelationshipError.confirmationRequiresUser(actor)
            }
            guard let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM relationship_stage_history WHERE id = ?",
                arguments: [id]
            ) else {
                throw RelationshipError.changeNotFound(id)
            }
            guard status == RelationshipStageChangeStatus.pending.rawValue else {
                throw RelationshipError.changeResolved(status)
            }
            try db.execute(
                sql: """
                UPDATE relationship_stage_history
                   SET status = 'rejected', resolved_at = ?
                 WHERE id = ?
                """,
                arguments: [self.now(), id]
            )
        }
    }

    // MARK: - 里程碑

    @discardableResult
    public func addMilestone(_ draft: RelationshipMilestoneDraft) async throws -> RelationshipMilestone {
        try await database.write { db in
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw RelationshipError.invalidMilestone("标题不能为空")
            }
            guard draft.occurredAt > 0 else {
                throw RelationshipError.invalidMilestone("发生时间不合法")
            }
            let importance = draft.importance.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["low", "normal", "high"].contains(importance) else {
                throw RelationshipError.invalidMilestone("重要度只能是 low / normal / high")
            }
            if let memoryID = draft.memoryID {
                guard try self.exists(db, table: "memories", id: memoryID) else {
                    throw RelationshipError.memoryNotFound(memoryID)
                }
            }
            if let episodeID = draft.episodeID {
                guard try self.exists(db, table: "episodes", id: episodeID) else {
                    throw RelationshipError.episodeNotFound(episodeID)
                }
            }

            let at = self.now()
            let id = UUID().uuidString
            try db.execute(
                sql: """
                INSERT INTO relationship_milestones
                    (id, kind, title, summary, occurred_at, time_precision, importance,
                     memory_id, episode_id, source_kind, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
                """,
                arguments: [
                    id, draft.kind.rawValue, title, draft.summary, draft.occurredAt,
                    draft.timePrecision.rawValue, importance, draft.memoryID, draft.episodeID,
                    draft.sourceKind.rawValue, at, at
                ]
            )
            return RelationshipMilestone(
                id: id,
                kind: draft.kind,
                title: title,
                summary: draft.summary,
                occurredAt: draft.occurredAt,
                timePrecision: draft.timePrecision,
                importance: importance,
                memoryID: draft.memoryID,
                episodeID: draft.episodeID,
                sourceKind: draft.sourceKind,
                status: "active",
                createdAt: at,
                updatedAt: at
            )
        }
    }

    // MARK: - 内部

    private struct ProfileRow {
        var exists: Bool
        var partnerName: String = ""
        var stage: RelationshipStage = .unset
        var closeness: Double = 0.5
        var summary: String = ""
        var updatedAt: Int64 = 0
    }

    private func loadProfile(_ db: Database) throws -> RelationshipProfile {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, partner_name, stage, stage_since, closeness, summary,
                   evidence_json, confirmed_by, confirmed_at, updated_at
              FROM relationship_profile WHERE id = ?
            """,
            arguments: [Self.primaryProfileID]
        ) else {
            return .defaultValue(id: Self.primaryProfileID, at: self.now())
        }
        return RelationshipProfile(
            id: try row.decode(String.self, forColumn: "id"),
            partnerName: (try? row.decode(String.self, forColumn: "partner_name")) ?? "",
            stage: RelationshipStage.parse((try? row.decode(String.self, forColumn: "stage")) ?? "") ?? .unset,
            stageSince: Self.optionalInt64(row, "stage_since"),
            closeness: (try? row.decode(Double.self, forColumn: "closeness")) ?? 0.5,
            summary: (try? row.decode(String.self, forColumn: "summary")) ?? "",
            evidenceJSON: (try? row.decode(String.self, forColumn: "evidence_json")) ?? "[]",
            confirmedBy: Self.optionalString(row, "confirmed_by"),
            confirmedAt: Self.optionalInt64(row, "confirmed_at"),
            updatedAt: (try? row.decode(Int64.self, forColumn: "updated_at")) ?? 0
        )
    }

    private func loadProfileRow(_ db: Database) throws -> ProfileRow {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT partner_name, stage, closeness, summary, updated_at FROM relationship_profile WHERE id = ?",
            arguments: [Self.primaryProfileID]
        ) else {
            return ProfileRow(exists: false)
        }
        return ProfileRow(
            exists: true,
            partnerName: (try? row.decode(String.self, forColumn: "partner_name")) ?? "",
            stage: RelationshipStage.parse((try? row.decode(String.self, forColumn: "stage")) ?? "") ?? .unset,
            closeness: (try? row.decode(Double.self, forColumn: "closeness")) ?? 0.5,
            summary: (try? row.decode(String.self, forColumn: "summary")) ?? "",
            updatedAt: (try? row.decode(Int64.self, forColumn: "updated_at")) ?? 0
        )
    }

    private func profileRowExists(_ db: Database) throws -> Bool {
        try self.exists(db, table: "relationship_profile", id: Self.primaryProfileID)
    }

    private func exists(_ db: Database, table: String, id: String) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM \(table) WHERE id = ?",
            arguments: [id]
        ) ?? 0
        return count > 0
    }

    // MARK: 编解码

    private static func decodeChange(_ row: Row) -> RelationshipStageChange {
        RelationshipStageChange(
            id: (try? row.decode(String.self, forColumn: "id")) ?? "",
            fromStage: RelationshipStage.parse(Self.optionalString(row, "from_stage") ?? "") ?? .unset,
            toStage: RelationshipStage.parse(Self.optionalString(row, "to_stage") ?? "") ?? .unset,
            reason: (try? row.decode(String.self, forColumn: "reason")) ?? "",
            evidenceJSON: (try? row.decode(String.self, forColumn: "evidence_json")) ?? "[]",
            decidedBy: (try? row.decode(String.self, forColumn: "decided_by")) ?? "",
            status: RelationshipStageChangeStatus(
                rawValue: (try? row.decode(String.self, forColumn: "status")) ?? ""
            ) ?? .pending,
            memoryID: Self.optionalString(row, "memory_id"),
            createdAt: (try? row.decode(Int64.self, forColumn: "created_at")) ?? 0,
            resolvedAt: Self.optionalInt64(row, "resolved_at")
        )
    }

    private static func decodeMilestone(_ row: Row) -> RelationshipMilestone {
        RelationshipMilestone(
            id: (try? row.decode(String.self, forColumn: "id")) ?? "",
            kind: RelationshipMilestoneKind(
                rawValue: (try? row.decode(String.self, forColumn: "kind")) ?? ""
            ) ?? .other,
            title: (try? row.decode(String.self, forColumn: "title")) ?? "",
            summary: (try? row.decode(String.self, forColumn: "summary")) ?? "",
            occurredAt: (try? row.decode(Int64.self, forColumn: "occurred_at")) ?? 0,
            timePrecision: RelationshipTimePrecision(
                rawValue: (try? row.decode(String.self, forColumn: "time_precision")) ?? ""
            ) ?? .day,
            importance: (try? row.decode(String.self, forColumn: "importance")) ?? "normal",
            memoryID: Self.optionalString(row, "memory_id"),
            episodeID: Self.optionalString(row, "episode_id"),
            sourceKind: RelationshipSourceKind(
                rawValue: (try? row.decode(String.self, forColumn: "source_kind")) ?? ""
            ) ?? .userConfirmed,
            status: (try? row.decode(String.self, forColumn: "status")) ?? "active",
            createdAt: (try? row.decode(Int64.self, forColumn: "created_at")) ?? 0,
            updatedAt: (try? row.decode(Int64.self, forColumn: "updated_at")) ?? 0
        )
    }

    /// 证据必须是 JSON 数组（允许空数组），防止把自由文本塞进证据字段
    private static func isJSONArray(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return object is [Any]
    }

    private static func optionalString(_ row: Row, _ column: String) -> String? {
        guard row.hasColumn(column) else { return nil }
        return String.fromDatabaseValue(row[column])
    }

    private static func optionalInt64(_ row: Row, _ column: String) -> Int64? {
        guard row.hasColumn(column) else { return nil }
        return Int64.fromDatabaseValue(row[column])
    }
}
