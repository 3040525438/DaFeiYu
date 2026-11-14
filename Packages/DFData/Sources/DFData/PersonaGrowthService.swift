import Foundation
import GRDB
import DFCore

/// 人格成长：提案 → 用户审批 → 写入外围人格 → 版本留痕；以及版本回退。
///
/// 硬规则（决策 30–32 / P-05 / P-11）：
/// - 核心人格 `kind = core` **受写保护**，AI 提案一律拒绝；
/// - 只有 `pending` 提案能被审批/驳回，重复操作直接报错；
/// - 每次审批与回退都写入新的 `persona_versions` 全量快照，并重算指纹；
/// - 版本快照缺失或损坏时拒绝回退，不做"猜一个"的修复。
public final class PersonaGrowthService: @unchecked Sendable {
    private let database: AppDatabase
    private let now: @Sendable () -> Int64

    public init(database: AppDatabase, now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }) {
        self.database = database
        self.now = now
    }

    // MARK: - 提案

    @discardableResult
    public func propose(_ draft: PersonaGrowthDraft) async throws -> PersonaGrowthProposal {
        try await database.write { db in
            guard let persona = try self.loadPersona(db, id: draft.personaID) else {
                throw PersonaGrowthError.personaNotFound(draft.personaID)
            }
            guard persona.kind == PersonaKind.outer.rawValue else {
                throw PersonaGrowthError.coreProtected(persona.name)
            }
            guard !draft.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PersonaGrowthError.invalidDraft("key 不能为空")
            }
            guard !draft.toValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PersonaGrowthError.invalidDraft("提案内容不能为空")
            }
            guard !draft.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PersonaGrowthError.invalidDraft("必须写明提案理由")
            }

            let at = self.now()
            let id = UUID().uuidString
            let payload = try Self.encodePayload(draft, at: at)
            try db.execute(
                sql: """
                INSERT INTO proposals
                    (id, kind, payload_json, reason, evidence_json, status, created_at)
                VALUES (?, 'persona_growth', ?, ?, ?, 'pending', ?)
                """,
                arguments: [id, payload, draft.reason, draft.evidenceJSON, at]
            )
            return PersonaGrowthProposal(
                id: id,
                personaID: draft.personaID,
                itemID: draft.itemID,
                section: draft.section,
                key: draft.key,
                fromValue: draft.fromValue,
                toValue: draft.toValue,
                reason: draft.reason,
                evidenceJSON: draft.evidenceJSON,
                status: "pending",
                createdAt: at,
                resolvedAt: nil,
                resolutionNote: nil
            )
        }
    }

    public func proposals(personaID: String? = nil) async throws -> [PersonaGrowthProposal] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, payload_json, reason, evidence_json, status, created_at, resolved_at, resolution_note
                  FROM proposals
                 WHERE kind = 'persona_growth'
                 ORDER BY created_at DESC
                """
            )
            var result: [PersonaGrowthProposal] = []
            for row in rows {
                guard let payload = Self.decodePayload(try row.decode(String.self, forColumn: "payload_json")) else {
                    continue
                }
                if let personaID, payload.personaID != personaID { continue }
                result.append(
                    PersonaGrowthProposal(
                        id: try row.decode(String.self, forColumn: "id"),
                        personaID: payload.personaID,
                        itemID: payload.itemID,
                        section: payload.section,
                        key: payload.key,
                        fromValue: payload.fromValue,
                        toValue: payload.toValue,
                        reason: try row.decode(String.self, forColumn: "reason"),
                        evidenceJSON: try row.decode(String.self, forColumn: "evidence_json"),
                        status: try row.decode(String.self, forColumn: "status"),
                        createdAt: try row.decode(Int64.self, forColumn: "created_at"),
                        resolvedAt: Self.optionalInt64(row, "resolved_at"),
                        resolutionNote: Self.optionalString(row, "resolution_note")
                    )
                )
            }
            return result
        }
    }

    // MARK: - 审批 / 驳回

    @discardableResult
    public func approve(id: String) async throws -> PersonaGrowthProposal {
        try await database.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, payload_json, reason, evidence_json, status, created_at
                  FROM proposals WHERE id = ? AND kind = 'persona_growth'
                """,
                arguments: [id]
            ) else {
                throw PersonaGrowthError.proposalNotFound(id)
            }
            let status = try row.decode(String.self, forColumn: "status")
            guard status == "pending" else {
                throw PersonaGrowthError.proposalResolved(status)
            }
            guard let payload = Self.decodePayload(try row.decode(String.self, forColumn: "payload_json")) else {
                throw PersonaGrowthError.invalidSnapshot("提案 payload 无法解析")
            }
            guard let persona = try self.loadPersona(db, id: payload.personaID) else {
                throw PersonaGrowthError.personaNotFound(payload.personaID)
            }
            guard persona.kind == PersonaKind.outer.rawValue else {
                throw PersonaGrowthError.coreProtected(persona.name)
            }

            let at = self.now()
            if let itemID = payload.itemID {
                guard try self.itemExists(db, id: itemID, personaID: payload.personaID) else {
                    throw PersonaGrowthError.itemNotFound(itemID)
                }
                try db.execute(
                    sql: """
                    UPDATE persona_items
                       SET value = ?, source = 'growth_proposal', tier = 'outer',
                           tier_status = 'outer', tier_source = 'growth_proposal', updated_at = ?
                     WHERE id = ? AND persona_id = ?
                    """,
                    arguments: [payload.toValue, at, itemID, payload.personaID]
                )
                try db.execute(
                    sql: """
                    INSERT INTO persona_item_tier_history
                        (id, item_id, from_tier, to_tier, from_status, to_status, reason,
                         evidence_json, decided_by, created_at)
                    VALUES (?, ?, 'outer', 'outer', 'active', 'active', ?, ?, 'user', ?)
                    """,
                    arguments: [UUID().uuidString, itemID, "成长提案审批：\(payload.key)", payload.evidenceJSON, at]
                )
            } else {
                try self.insertItem(
                    db,
                    personaID: payload.personaID,
                    section: payload.section,
                    key: payload.key,
                    value: payload.toValue,
                    source: "growth_proposal",
                    tier: "outer",
                    at: at
                )
            }

            try self.bumpVersion(
                db,
                personaID: payload.personaID,
                name: persona.name,
                changeReason: "成长提案：\(payload.key)",
                changedBy: "user",
                at: at
            )
            try db.execute(
                sql: """
                UPDATE proposals
                   SET status = 'approved', resolved_at = ?
                 WHERE id = ?
                """,
                arguments: [at, id]
            )
            return PersonaGrowthProposal(
                id: id,
                personaID: payload.personaID,
                itemID: payload.itemID,
                section: payload.section,
                key: payload.key,
                fromValue: payload.fromValue,
                toValue: payload.toValue,
                reason: try row.decode(String.self, forColumn: "reason"),
                evidenceJSON: try row.decode(String.self, forColumn: "evidence_json"),
                status: "approved",
                createdAt: try row.decode(Int64.self, forColumn: "created_at"),
                resolvedAt: at,
                resolutionNote: nil
            )
        }
    }

    public func reject(id: String, note: String) async throws {
        try await database.write { db in
            guard let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM proposals WHERE id = ? AND kind = 'persona_growth'",
                arguments: [id]
            ) else {
                throw PersonaGrowthError.proposalNotFound(id)
            }
            guard status == "pending" else {
                throw PersonaGrowthError.proposalResolved(status)
            }
            try db.execute(
                sql: """
                UPDATE proposals
                   SET status = 'rejected', resolved_at = ?, resolution_note = ?
                 WHERE id = ?
                """,
                arguments: [self.now(), note, id]
            )
        }
    }

    // MARK: - 版本

    public func versions(personaID: String) async throws -> [PersonaVersion] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, persona_id, version, snapshot_json, change_reason, changed_by, created_at
                  FROM persona_versions
                 WHERE persona_id = ?
                 ORDER BY version DESC
                """,
                arguments: [personaID]
            )
            return rows.map { row in
                PersonaVersion(
                    id: (try? row.decode(String.self, forColumn: "id")) ?? "",
                    personaID: (try? row.decode(String.self, forColumn: "persona_id")) ?? personaID,
                    version: (try? row.decode(Int.self, forColumn: "version")) ?? 0,
                    snapshotJSON: (try? row.decode(String.self, forColumn: "snapshot_json")) ?? "{}",
                    changeReason: (try? row.decode(String.self, forColumn: "change_reason")) ?? "",
                    changedBy: (try? row.decode(String.self, forColumn: "changed_by")) ?? "",
                    createdAt: (try? row.decode(Int64.self, forColumn: "created_at")) ?? 0
                )
            }
        }
    }

    /// 回退到指定版本：以该版本快照**新建一个版本**，历史不删除、可再回退。
    @discardableResult
    public func restore(personaID: String, version: Int) async throws -> PersonaVersion {
        try await database.write { db in
            guard let persona = try self.loadPersona(db, id: personaID) else {
                throw PersonaGrowthError.personaNotFound(personaID)
            }
            guard let snapshot = try String.fetchOne(
                db,
                sql: "SELECT snapshot_json FROM persona_versions WHERE persona_id = ? AND version = ?",
                arguments: [personaID, version]
            ) else {
                throw PersonaGrowthError.versionNotFound(personaID: personaID, version: version)
            }
            guard let items = Self.decodeSnapshotItems(snapshot) else {
                throw PersonaGrowthError.invalidSnapshot("版本 \(version) 的快照缺少 items")
            }

            let at = self.now()
            try db.execute(sql: "DELETE FROM persona_items WHERE persona_id = ?", arguments: [personaID])
            let tier = persona.kind == PersonaKind.core.rawValue ? "core" : "outer"
            for item in items {
                try self.insertItem(
                    db,
                    personaID: personaID,
                    section: item.section,
                    key: item.key,
                    value: item.value,
                    source: "version_restore",
                    tier: tier,
                    at: at
                )
            }

            let newVersion = try self.bumpVersion(
                db,
                personaID: personaID,
                name: persona.name,
                changeReason: "回退到版本 \(version)",
                changedBy: "user",
                at: at
            )
            return PersonaVersion(
                id: UUID().uuidString,
                personaID: personaID,
                version: newVersion,
                snapshotJSON: try String.fetchOne(
                    db,
                    sql: "SELECT snapshot_json FROM persona_versions WHERE persona_id = ? AND version = ?",
                    arguments: [personaID, newVersion]
                ) ?? "{}",
                changeReason: "回退到版本 \(version)",
                changedBy: "user",
                createdAt: at
            )
        }
    }

    /// 当前指纹（用于界面展示"人格是否漂移"）
    public func fingerprint(personaID: String, scope: PersonaFingerprint.Scope) async throws -> String {
        try await database.dbQueue.read { db in
            let items = try self.loadFingerprintItems(db, personaID: personaID)
            return PersonaFingerprint.compute(items: items, scope: scope).fingerprint
        }
    }

    // MARK: - 内部

    private struct Owner {
        var id: String
        var kind: String
        var name: String
        var currentVersion: Int
    }

    private func loadPersona(_ db: Database, id: String) throws -> Owner? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT id, kind, name, current_version FROM personas WHERE id = ?",
            arguments: [id]
        ) else { return nil }
        return Owner(
            id: try row.decode(String.self, forColumn: "id"),
            kind: try row.decode(String.self, forColumn: "kind"),
            name: try row.decode(String.self, forColumn: "name"),
            currentVersion: try row.decode(Int.self, forColumn: "current_version")
        )
    }

    private func itemExists(_ db: Database, id: String, personaID: String) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM persona_items WHERE id = ? AND persona_id = ?",
            arguments: [id, personaID]
        ) ?? 0
        return count > 0
    }

    private func insertItem(
        _ db: Database,
        personaID: String,
        section: String,
        key: String,
        value: String,
        source: String,
        tier: String,
        at millis: Int64
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO persona_items
                (id, persona_id, section, key, value, confidence, weight, source, updated_at,
                 tier, tier_status, tier_source, status)
            VALUES (?, ?, ?, ?, ?, 0.8, 1.0, ?, ?, ?, ?, ?, 'active')
            """,
            arguments: [UUID().uuidString, personaID, section, key, value, source, millis, tier, source]
        )
    }

    @discardableResult
    private func bumpVersion(
        _ db: Database,
        personaID: String,
        name: String,
        changeReason: String,
        changedBy: String,
        at millis: Int64
    ) throws -> Int {
        let current = try Int.fetchOne(
            db,
            sql: "SELECT current_version FROM personas WHERE id = ?",
            arguments: [personaID]
        ) ?? 1
        let next = current + 1
        let items = try self.loadSnapshotItems(db, personaID: personaID)
        let snapshot = Self.encodeSnapshot(name: name, items: items)
        try db.execute(
            sql: """
            INSERT INTO persona_versions
                (id, persona_id, version, snapshot_json, change_reason, changed_by, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [UUID().uuidString, personaID, next, snapshot, changeReason, changedBy, millis]
        )
        try db.execute(
            sql: "UPDATE personas SET current_version = ?, updated_at = ? WHERE id = ?",
            arguments: [next, millis, personaID]
        )
        try self.refreshFingerprints(db, personaID: personaID, at: millis)
        return next
    }

    private func refreshFingerprints(_ db: Database, personaID: String, at millis: Int64) throws {
        let items = try loadFingerprintItems(db, personaID: personaID)
        let core = PersonaFingerprint.compute(items: items, scope: .core)
        let coreOuter = PersonaFingerprint.compute(items: items, scope: .coreOuter)

        try db.execute(
            sql: """
            UPDATE personas
               SET fingerprint = ?, fingerprint_scope = 'core', fingerprint_at = ?
             WHERE id = ?
            """,
            arguments: [core.fingerprint, millis, personaID]
        )
        for (scope, result) in [("core", core), ("core_outer", coreOuter)] {
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO persona_fingerprints
                    (id, persona_id, scope, algorithm, fingerprint, item_count, computed_at, trigger, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'persona_change', 'baseline')
                """,
                arguments: [
                    UUID().uuidString, personaID, scope, PersonaFingerprint.algorithm,
                    result.fingerprint, result.itemCount, millis
                ]
            )
        }
    }

    private func loadFingerprintItems(_ db: Database, personaID: String) throws -> [PersonaFingerprint.Item] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT key, value, coalesce(tier, 'pending') AS tier
              FROM persona_items
             WHERE persona_id = ? AND status = 'active'
               AND tier IN ('core', 'outer')
            """,
            arguments: [personaID]
        )
        return rows.compactMap { row in
            guard let key = try? row.decode(String.self, forColumn: "key"),
                  let value = try? row.decode(String.self, forColumn: "value"),
                  let tier = try? row.decode(String.self, forColumn: "tier") else { return nil }
            return PersonaFingerprint.Item(key: key, value: value, tier: tier)
        }
    }

    private func loadSnapshotItems(_ db: Database, personaID: String) throws -> [SnapshotItem] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT section, key, value FROM persona_items
             WHERE persona_id = ? AND status = 'active'
             ORDER BY section, key
            """,
            arguments: [personaID]
        )
        return rows.compactMap { row in
            guard let section = try? row.decode(String.self, forColumn: "section"),
                  let key = try? row.decode(String.self, forColumn: "key"),
                  let value = try? row.decode(String.self, forColumn: "value") else { return nil }
            return SnapshotItem(section: section, key: key, value: value)
        }
    }

    // MARK: 编解码

    private struct SnapshotItem: Codable, Sendable {
        var section: String
        var key: String
        var value: String
    }

    private struct Payload: Codable, Sendable {
        var personaID: String
        var itemID: String?
        var section: String
        var key: String
        var fromValue: String
        var toValue: String
        var proposedAt: Int64

        enum CodingKeys: String, CodingKey {
            case personaID = "persona_id"
            case itemID = "item_id"
            case section
            case key
            case fromValue = "from_value"
            case toValue = "to_value"
            case proposedAt = "proposed_at"
        }
    }

    private static func encodePayload(_ draft: PersonaGrowthDraft, at millis: Int64) throws -> String {
        let payload = Payload(
            personaID: draft.personaID,
            itemID: draft.itemID,
            section: draft.section,
            key: draft.key,
            fromValue: draft.fromValue,
            toValue: draft.toValue,
            proposedAt: millis
        )
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PersonaGrowthError.invalidDraft("payload 编码失败")
        }
        return text
    }

    private static func decodePayload(_ json: String) -> Payload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private static func encodeSnapshot(name: String, items: [SnapshotItem]) -> String {
        let payload: [String: Any] = [
            "name": name,
            "items": items.map { ["section": $0.section, "key": $0.key, "value": $0.value] }
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func decodeSnapshotItems(_ json: String) -> [SnapshotItem]? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["items"] as? [[String: Any]] else {
            return nil
        }
        return raw.compactMap { dict in
            guard let section = dict["section"] as? String,
                  let key = dict["key"] as? String,
                  let value = dict["value"] as? String else { return nil }
            return SnapshotItem(section: section, key: key, value: value)
        }
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
