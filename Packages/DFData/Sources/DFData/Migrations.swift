import Foundation
import GRDB
import DFCore

/// 数据库迁移。
/// 规则：
/// 1. 每个迁移一旦发布就不可修改，只能新增下一个版本。
/// 2. 迁移里不允许调用网络或模型。
/// 3. 事务由 GRDB 的 DatabaseMigrator 保证。
/// 4. 注册顺序必须与 `MigrationID` 的规范顺序一致，不允许提前注册未到阶段的迁移。
public enum Migrations {
    /// 生产入口：注册全部已发布迁移
    public static var migrator: DatabaseMigrator {
        makeMigrator(upTo: .v7_meta_backup)
    }

    /// 按规范顺序注册，最多注册到 `last`（测试用：`upTo: .v1_phase1` 可构造 v1 库）
    static func makeMigrator(upTo last: MigrationID) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_phase1") { db in
            // 会话
            try db.execute(sql: """
            CREATE TABLE conversations (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT 'main',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                archived_at INTEGER
            )
            """)

            // 消息
            try db.execute(sql: """
            CREATE TABLE messages (
                id TEXT PRIMARY KEY,
                client_uuid TEXT NOT NULL UNIQUE,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                kind TEXT NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL,
                origin TEXT NOT NULL,
                reply_to_id TEXT,
                created_at INTEGER NOT NULL,
                sent_at INTEGER,
                model_config_id TEXT,
                emotion_state_id TEXT,
                deleted_at INTEGER
            )
            """)
            try db.execute(sql: "CREATE INDEX ix_messages_conv_time ON messages(conversation_id, created_at)")
            try db.execute(sql: "CREATE INDEX ix_messages_conv_status ON messages(conversation_id, status)")

            // 人格
            try db.execute(sql: """
            CREATE TABLE personas (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                is_locked INTEGER NOT NULL DEFAULT 0,
                current_version INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE persona_items (
                id TEXT PRIMARY KEY,
                persona_id TEXT NOT NULL REFERENCES personas(id) ON DELETE CASCADE,
                section TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                confidence REAL NOT NULL DEFAULT 1.0,
                weight REAL NOT NULL DEFAULT 1.0,
                source TEXT NOT NULL DEFAULT 'user',
                updated_at INTEGER NOT NULL
            )
            """)
            try db.execute(sql: "CREATE INDEX ix_persona_items_persona ON persona_items(persona_id)")
            try db.execute(sql: """
            CREATE TABLE persona_versions (
                id TEXT PRIMARY KEY,
                persona_id TEXT NOT NULL REFERENCES personas(id) ON DELETE CASCADE,
                version INTEGER NOT NULL,
                snapshot_json TEXT NOT NULL,
                change_reason TEXT NOT NULL,
                changed_by TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """)
            try db.execute(sql: "CREATE UNIQUE INDEX ux_persona_versions ON persona_versions(persona_id, version)")

            // 模型配置（密钥不在此表）
            try db.execute(sql: """
            CREATE TABLE model_configs (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                provider_kind TEXT NOT NULL DEFAULT 'openaiCompatible',
                base_url TEXT NOT NULL,
                model_id TEXT NOT NULL,
                key_ref TEXT NOT NULL,
                is_default INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """)

            // 附件索引
            try db.execute(sql: """
            CREATE TABLE attachments (
                id TEXT PRIMARY KEY,
                sha256 TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                rel_path TEXT NOT NULL,
                byte_size INTEGER NOT NULL,
                mime TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE message_attachments (
                message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                attachment_id TEXT NOT NULL REFERENCES attachments(id) ON DELETE CASCADE,
                sort INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (message_id, attachment_id)
            )
            """)

            // 键值设置
            try db.execute(sql: """
            CREATE TABLE settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)

            // AI 变更提案（阶段二起使用，先建表锁定结构）
            try db.execute(sql: """
            CREATE TABLE proposals (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                reason TEXT,
                evidence_json TEXT,
                status TEXT NOT NULL DEFAULT 'pending',
                created_at INTEGER NOT NULL,
                resolved_at INTEGER,
                resolution_note TEXT
            )
            """)

            // 以下为后续阶段占位表：第一阶段只建结构，不写入业务逻辑
            try db.execute(sql: """
            CREATE TABLE memories (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                importance TEXT NOT NULL DEFAULT 'normal',
                salience REAL NOT NULL DEFAULT 0.5,
                confidence REAL NOT NULL DEFAULT 0.5,
                valid_from INTEGER,
                valid_to INTEGER,
                status TEXT NOT NULL DEFAULT 'active',
                first_seen_at INTEGER NOT NULL,
                last_recalled_at INTEGER,
                recall_count INTEGER NOT NULL DEFAULT 0
            )
            """)
            try db.execute(sql: """
            CREATE TABLE timeline_events (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                occurred_at INTEGER NOT NULL,
                precision TEXT NOT NULL DEFAULT 'day',
                importance TEXT NOT NULL DEFAULT 'normal',
                refs_json TEXT
            )
            """)
            try db.execute(sql: """
            CREATE TABLE proactive_intents (
                id TEXT PRIMARY KEY,
                created_at INTEGER NOT NULL,
                type TEXT NOT NULL,
                reason TEXT,
                evidence_json TEXT,
                confidence REAL NOT NULL DEFAULT 0.5,
                status TEXT NOT NULL DEFAULT 'new'
            )
            """)
            try db.execute(sql: """
            CREATE TABLE proactive_messages (
                id TEXT PRIMARY KEY,
                intent_id TEXT,
                planned_at INTEGER NOT NULL,
                text TEXT NOT NULL,
                is_voice INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'planned',
                suppress_reason TEXT,
                notification_id TEXT,
                resolved_at INTEGER
            )
            """)
        }

        if includes(.v2_memory, upTo: last) {
            migrator.registerMigration("v2_memory") { db in
                try V2Memory.migrate(db)
            }
        }

        if includes(.v3_chat, upTo: last) {
            migrator.registerMigration("v3_chat") { db in
                try V3Chat.migrate(db)
            }
        }

        if includes(.v4_persona, upTo: last) {
            migrator.registerMigration("v4_persona") { db in
                try V4Persona.migrate(db)
            }
        }

        return migrator
    }

    /// 判断某个迁移是否应被注册（按规范顺序比较，不按名称排序）
    private static func includes(_ id: MigrationID, upTo last: MigrationID) -> Bool {
        let ids = MigrationID.allCases
        guard let target = ids.firstIndex(of: id), let bound = ids.firstIndex(of: last) else {
            return false
        }
        return target <= bound
    }
}
