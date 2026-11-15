import Foundation
import GRDB
import DFCore

/// 当前启用角色的读取与兜底创建（D36 / D37）。
///
/// 边界：
/// - 只负责"哪个角色在用"这一件事，不碰表情定义、状态与历史；
/// - 角色由用户确认后创建属于产品口径，这里只在**一个角色都没有**时补建内置角色，
///   否则界面拿不到 `character_states` 的宿主，情绪与表情永远无法落库；
/// - 任意时刻最多一个 `is_active = 1`，保证状态读取不歧义。
public final class CharacterProfileService: @unchecked Sendable {
    /// 内置角色的固定 id：重复调用不会产生第二个角色
    public static let defaultCharacterID = "character-dafeiyu"
    public static let defaultCharacterName = "大肥鱼"

    private let database: AppDatabase
    private let now: @Sendable () -> Int64

    public init(database: AppDatabase, now: @escaping @Sendable () -> Int64 = { Clock.nowMillis() }) {
        self.database = database
        self.now = now
    }

    /// 当前启用角色 id；一个角色都没有时补建内置角色后返回。
    public func activeCharacterID() async throws -> String {
        try await database.write { db in
            try self.ensureOneActive(db)
        }
    }

    /// 确保存在一个启用角色（幂等）。返回最终启用的 id。
    @discardableResult
    public func ensureDefaultCharacter(
        name: String = CharacterProfileService.defaultCharacterName
    ) async throws -> String {
        try await database.write { db in
            try self.ensureOneActive(db, name: name)
        }
    }

    /// 先取启用角色，没有就取最早的角色，都没有才插入内置角色；
    /// 随后把 `is_active` 归一化为"只有它一个"。
    /// 调用方必须已在写事务内。
    private func ensureOneActive(_ db: Database, name: String = CharacterProfileService.defaultCharacterName) throws -> String {
        if let candidate = try String.fetchOne(
            db,
            sql: "SELECT id FROM characters WHERE is_active = 1 ORDER BY sort ASC, created_at ASC, id ASC LIMIT 1"
        ) ?? String.fetchOne(
            db,
            sql: "SELECT id FROM characters ORDER BY sort ASC, created_at ASC, id ASC LIMIT 1"
        ) {
            try db.execute(sql: "UPDATE characters SET is_active = CASE WHEN id = ? THEN 1 ELSE 0 END", arguments: [candidate])
            return candidate
        }

        let at = now()
        try db.execute(
            sql: """
            INSERT INTO characters (id, name, kind, summary, is_active, sort, created_at, updated_at)
            VALUES (?, ?, 'builtin', '', 1, 0, ?, ?)
            """,
            arguments: [Self.defaultCharacterID, name, at, at]
        )
        return Self.defaultCharacterID
    }
}
