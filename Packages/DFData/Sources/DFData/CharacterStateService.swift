import Foundation
import GRDB
import DFCore

/// 角色状态读写（D36）：表情、精力、亲和，以及状态变更历史。
///
/// 边界：
/// - 一个角色只有一行 `character_states`（唯一索引保证）；
/// - 任何表情变化都必须留 `character_state_history`，不允许无记录跳变；
/// - 数值一律夹取到 0–1，脏数据不写库；
/// - 不做动画渲染，只提供 `CharacterPresentation` 需要的原始状态。
public final class CharacterStateService: @unchecked Sendable {
    public struct State: Sendable, Equatable {
        public var characterID: String
        public var mood: CharacterMood
        public var energy: Double
        public var affinity: Double
        /// system / chat / diary / user
        public var source: String
        public var contextJSON: String
        public var updatedAt: Int64

        public init(
            characterID: String,
            mood: CharacterMood,
            energy: Double,
            affinity: Double,
            source: String,
            contextJSON: String,
            updatedAt: Int64
        ) {
            self.characterID = characterID
            self.mood = mood
            self.energy = energy
            self.affinity = affinity
            self.source = source
            self.contextJSON = contextJSON
            self.updatedAt = updatedAt
        }

        /// 界面直接可用的一份展示参数
        public func presentation(reduceMotion: Bool = false) -> CharacterPresentation {
            CharacterPresentationPolicy.make(
                mood: mood,
                energy: energy,
                affinity: affinity,
                reduceMotion: reduceMotion
            )
        }
    }

    public struct HistoryEntry: Sendable, Equatable, Identifiable {
        public var id: String
        public var fromMood: CharacterMood?
        public var toMood: CharacterMood
        public var fromEnergy: Double?
        public var toEnergy: Double?
        public var reason: String
        public var triggerMessageID: String?
        public var createdAt: Int64
    }

    public enum StateError: Error, Equatable, CustomStringConvertible {
        case characterNotFound(String)
        case emptyReason

        public var description: String {
            switch self {
            case .characterNotFound(let id):
                return "角色不存在：\(id)"
            case .emptyReason:
                return "状态变更必须填写原因"
            }
        }
    }

    private let database: AppDatabase
    private let now: @Sendable () -> Int64

    public init(database: AppDatabase, now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }) {
        self.database = database
        self.now = now
    }

    // MARK: - 读取

    /// 读取角色状态；不存在则按默认值创建（不写历史，创建不是"变更"）。
    public func state(for characterID: String) async throws -> State {
        try await database.write { db in
            try self.ensureCharacter(db, characterID: characterID)
            if let existing = try Self.fetchState(db, characterID: characterID) {
                return existing
            }
            // 默认态：平静、精力中性、亲和中性
            let at = self.now()
            try db.execute(
                sql: """
                INSERT INTO character_states
                    (id, character_id, mood_code, energy, affinity, source, context_json, updated_at)
                VALUES (?, ?, ?, ?, ?, 'system', '{}', ?)
                """,
                arguments: [UUID().uuidString, characterID, CharacterMood.neutral.rawValue, 0.5, 0.5, at]
            )
            return State(
                characterID: characterID,
                mood: .neutral,
                energy: 0.5,
                affinity: 0.5,
                source: "system",
                contextJSON: "{}",
                updatedAt: at
            )
        }
    }

    public func history(for characterID: String, limit: Int = 20) async throws -> [HistoryEntry] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM character_state_history
                 WHERE character_id = ?
                 ORDER BY created_at DESC, rowid DESC
                 LIMIT ?
                """,
                arguments: [characterID, max(0, limit)]
            )
            return rows.map { row in
                HistoryEntry(
                    id: String.fromDatabaseValue(row["id"]) ?? "",
                    fromMood: String.fromDatabaseValue(row["from_mood"]).map { CharacterMood(stored: $0) },
                    toMood: CharacterMood(stored: String.fromDatabaseValue(row["to_mood"]) ?? ""),
                    fromEnergy: Double.fromDatabaseValue(row["from_energy"]),
                    toEnergy: Double.fromDatabaseValue(row["to_energy"]),
                    reason: String.fromDatabaseValue(row["reason"]) ?? "",
                    triggerMessageID: String.fromDatabaseValue(row["trigger_message_id"]),
                    createdAt: Int64.fromDatabaseValue(row["created_at"]) ?? 0
                )
            }
        }
    }

    // MARK: - 写入

    /// 更新角色状态。
    ///
    /// - 表情或精力发生变化才写历史；完全相同的重复写入直接返回当前状态（幂等）。
    /// - `reason` 为空视为非法，避免出现无法解释的情绪跳变。
    @discardableResult
    public func update(
        characterID: String,
        mood: CharacterMood,
        energy: Double,
        affinity: Double,
        source: String = "system",
        reason: String,
        triggerMessageID: String? = nil,
        contextJSON: String = "{}"
    ) async throws -> State {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else { throw StateError.emptyReason }

        let clampedEnergy = CharacterPresentationPolicy.clamp(energy)
        let clampedAffinity = CharacterPresentationPolicy.clamp(affinity)

        return try await database.write { db in
            try self.ensureCharacter(db, characterID: characterID)
            let at = self.now()
            // `state(for:)` 会写入默认行，这里直接用同一事务内的查询，避免嵌套写
            let previous = try Self.fetchState(db, characterID: characterID)
            let fromMood = previous?.mood
            let fromEnergy = previous?.energy

            if let previous {
                // 幂等：状态与原因都相同，不产生新历史
                if previous.mood == mood, previous.energy == clampedEnergy, previous.affinity == clampedAffinity {
                    return previous
                }
                try db.execute(
                    sql: """
                    UPDATE character_states
                       SET mood_code = ?, energy = ?, affinity = ?, source = ?,
                           context_json = ?, updated_at = ?
                     WHERE character_id = ?
                    """,
                    arguments: [mood.rawValue, clampedEnergy, clampedAffinity, source, contextJSON, at, characterID]
                )
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO character_states
                        (id, character_id, mood_code, energy, affinity, source, context_json, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString, characterID, mood.rawValue,
                        clampedEnergy, clampedAffinity, source, contextJSON, at
                    ]
                )
            }

            // 表情变化，或精力发生变化，都要留痕
            if fromMood != mood || fromEnergy != clampedEnergy {
                try db.execute(
                    sql: """
                    INSERT INTO character_state_history
                        (id, character_id, from_mood, to_mood, from_energy, to_energy,
                         reason, trigger_message_id, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString, characterID,
                        fromMood?.rawValue, mood.rawValue,
                        fromEnergy, clampedEnergy,
                        trimmedReason, triggerMessageID, at
                    ]
                )
            }

            return State(
                characterID: characterID,
                mood: mood,
                energy: clampedEnergy,
                affinity: clampedAffinity,
                source: source,
                contextJSON: contextJSON,
                updatedAt: at
            )
        }
    }

    /// 由 D37 情绪状态直接更新（表情与情绪一一映射）。
    @discardableResult
    public func update(
        characterID: String,
        emotion: EmotionState,
        source: String = "chat",
        energy: Double? = nil,
        affinity: Double? = nil,
        triggerMessageID: String? = nil
    ) async throws -> State {
        let current = try await state(for: characterID)
        return try await update(
            characterID: characterID,
            mood: CharacterMood(emotion: emotion.kind),
            energy: energy ?? current.energy,
            affinity: affinity ?? current.affinity,
            source: source,
            reason: emotion.reason ?? "情绪强度 \(String(format: "%.2f", emotion.intensity))",
            triggerMessageID: triggerMessageID
        )
    }

    // MARK: - 内部

    private func ensureCharacter(_ db: Database, characterID: String) throws {
        let exists = try Bool.fetchOne(
            db,
            sql: "SELECT 1 FROM characters WHERE id = ? LIMIT 1",
            arguments: [characterID]
        ) ?? false
        guard exists else { throw StateError.characterNotFound(characterID) }
    }

    private static func fetchState(_ db: Database, characterID: String) throws -> State? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM character_states WHERE character_id = ? LIMIT 1",
            arguments: [characterID]
        ) else { return nil }
        return State(
            characterID: characterID,
            mood: CharacterMood(stored: String.fromDatabaseValue(row["mood_code"]) ?? ""),
            energy: CharacterPresentationPolicy.clamp(Double.fromDatabaseValue(row["energy"]) ?? 0.5),
            affinity: CharacterPresentationPolicy.clamp(Double.fromDatabaseValue(row["affinity"]) ?? 0.5),
            source: String.fromDatabaseValue(row["source"]) ?? "system",
            contextJSON: String.fromDatabaseValue(row["context_json"]) ?? "{}",
            updatedAt: Int64.fromDatabaseValue(row["updated_at"]) ?? 0
        )
    }
}
