import Foundation
import GRDB
import DFCore

/// `v2_memory` 迁移：三套记忆（user / shared / self）+ 七层结构的物理承载 + 重要性双列 + 人格 tier。
///
/// 边界（P1 第 2 步）：
/// - 只建结构、回填、写 `schema_meta`；
/// - 不做检索、不做抽取、不导入 AstrBot 历史、不改 UI；
/// - 不动 `v1_phase1` 的任何 DDL。
enum V2Memory {
    /// FTS5 行数与 memories 行数必须相等
    /// - Parameter probe: FTS5 能力探测；默认在独立内存库中真实建表/插入/MATCH 验证
    static func migrate(_ db: Database, probe: FTS5Probing = MemoryFTS5Probe()) throws {
        let startedAt = Date()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let batch = "P1-v2_memory-\(now)"

        // 0. 预检：FTS5 可用性（行为探测，失败即中止，不写入任何结构）
        try probe.verify()

        // 1. 结构断言：禁止重复迁移
        try assertNotApplied(db)

        // 迁移前快照（用于 T02/T05 校验）
        let memoriesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? 0
        let messagesBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let contentHashBefore = try contentFingerprint(db)
        let personaBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM persona_items") ?? 0
        let personaHashBefore = try personaFingerprint(db)

        // 2. 元数据表 + 三套记忆注册
        try createMetaTables(db)

        // 3. memories 加列（不动旧列）
        try extendMemories(db)

        // 4. 其余业务表
        try createDomainTables(db)

        // 5. FTS5 虚表（不挂外部内容表，bigram 由应用层生成）
        try createFullTextSearch(db)

        // 6. 索引与视图
        try createIndexesAndViews(db)

        // 7. 回填
        try backfill(db, now: now)
        try backfillPersonaTier(db, now: now, batch: batch)

        // 8. 校验
        try validate(
            db,
            memoriesBefore: memoriesBefore,
            messagesBefore: messagesBefore,
            contentHashBefore: contentHashBefore,
            personaBefore: personaBefore,
            personaHashBefore: personaHashBefore
        )

        // 9. 写 schema_meta（含 ledger_digest）
        let appliedBefore = try SchemaMeta.appliedIdentifiers(db)
        let expected = try SchemaMeta.expectedPrefixIncluding(current: .v2_memory, appliedBefore: appliedBefore)
        guard let version = expected.last else {
            throw DFError.database("v2_memory 预期前缀为空")
        }
        let digest = MigrationLedger.digest(prefix: expected)

        try SchemaMeta.write(db, key: SchemaMetaKey.schemaVersion, value: version, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.appliedPhase, value: "P1", at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migrationBatch, value: batch, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.migratedAt, value: String(now), at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.ledgerDigest, value: digest, at: now)
        try SchemaMeta.write(db, key: SchemaMetaKey.expectedMigrations, value: String(expected.count), at: now)

        // 停止条件：单次迁移不得超过 30 秒
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed <= 30 else {
            throw DFError.database(String(format: "v2_memory 迁移耗时 %.1fs，超过 30 秒上限", elapsed))
        }
    }

    // MARK: - 1. 结构断言

    private static func assertNotApplied(_ db: Database) throws {
        if try SchemaMeta.tableExists(db) {
            throw DFError.database("schema_meta 已存在，v2_memory 不可重复执行")
        }
        let columns = try ColumnInfoRow.fetchAll(db, sql: "PRAGMA table_info(memories)")
        let names = columns.map(\.name)
        guard !names.isEmpty else {
            throw DFError.database("memories 表不存在，数据库不处于 v1_phase1")
        }
        if names.contains("scope") || names.contains("importance_score") {
            throw DFError.database("memories 已包含 v2 列，禁止重复迁移")
        }
    }

    // MARK: - 2. 元数据

    private static func createMetaTables(_ db: Database) throws {
        try SchemaMeta.createTable(db)

        try db.execute(sql: """
        CREATE TABLE memory_scopes (
            id           TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            description  TEXT NOT NULL DEFAULT '',
            policy_json  TEXT NOT NULL DEFAULT '{}',
            created_at   INTEGER NOT NULL
        )
        """)

        try db.execute(
            sql: """
            INSERT INTO memory_scopes (id, display_name, description, policy_json, created_at) VALUES
             ('user',   '用户记忆', '关于用户的稳定事实、兴趣、偏好、习惯、观点变化', '{"scope_weight":0.95,"decay_tau_days":730}', 0),
             ('shared', '共同记忆', '双方真实发生过的互动、共同经历、关系与时间线',   '{"scope_weight":1.0,"decay_tau_days":3650}', 0),
             ('self',   '自身记忆', '大肥鱼自己的兴趣、想法、反思、计划与阶段性总结', '{"scope_weight":0.9,"decay_tau_days":365}', 0)
            """
        )
    }

    // MARK: - 3. memories 扩展

    private static func extendMemories(_ db: Database) throws {
        let statements = [
            "ALTER TABLE memories ADD COLUMN scope TEXT NOT NULL DEFAULT 'shared'",
            "ALTER TABLE memories ADD COLUMN layer TEXT NOT NULL DEFAULT 'semantic'",
            "ALTER TABLE memories ADD COLUMN category TEXT NOT NULL DEFAULT 'fact'",
            "ALTER TABLE memories ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'real_interaction'",
            "ALTER TABLE memories ADD COLUMN epistemic_status TEXT NOT NULL DEFAULT 'observed'",
            "ALTER TABLE memories ADD COLUMN version INTEGER NOT NULL DEFAULT 1",
            "ALTER TABLE memories ADD COLUMN subject_entity_id TEXT",
            "ALTER TABLE memories ADD COLUMN dedupe_key TEXT",
            "ALTER TABLE memories ADD COLUMN heat TEXT NOT NULL DEFAULT 'warm'",
            "ALTER TABLE memories ADD COLUMN archived_at INTEGER",
            "ALTER TABLE memories ADD COLUMN deleted_at INTEGER",
            "ALTER TABLE memories ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE memories ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0",
            // 重要度双列（D-A）：旧 importance TEXT 语义不变
            "ALTER TABLE memories ADD COLUMN importance_score REAL",
            "ALTER TABLE memories ADD COLUMN importance_source TEXT NOT NULL DEFAULT 'unparsed'",
            "ALTER TABLE memories ADD COLUMN importance_source_at INTEGER",
            // 分类治理（D2）：历史数据暂存 shared，归属未确认
            "ALTER TABLE memories ADD COLUMN classification_status TEXT NOT NULL DEFAULT 'pending'",
            "ALTER TABLE memories ADD COLUMN original_external_id TEXT",
            "ALTER TABLE memories ADD COLUMN original_content TEXT",
            "ALTER TABLE memories ADD COLUMN original_created_at INTEGER",
            "ALTER TABLE memories ADD COLUMN import_batch_id TEXT",
            "ALTER TABLE memories ADD COLUMN classification_evidence_json TEXT NOT NULL DEFAULT '[]'",
            "ALTER TABLE memories ADD COLUMN classified_by TEXT",
            "ALTER TABLE memories ADD COLUMN classified_at INTEGER"
        ]
        for statement in statements {
            try db.execute(sql: statement)
        }
    }

    // MARK: - 4. 业务表

    private static func createDomainTables(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE memory_importance_history (
            id          TEXT PRIMARY KEY,
            memory_id   TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            from_source TEXT,
            to_source   TEXT NOT NULL,
            from_score  REAL,
            to_score    REAL,
            reason      TEXT NOT NULL,
            evidence    TEXT,
            decided_by  TEXT NOT NULL,
            created_at  INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_importance_history_memory ON memory_importance_history(memory_id, created_at)")

        try db.execute(sql: """
        CREATE TABLE memory_sources (
            id          TEXT PRIMARY KEY,
            memory_id   TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            source_type TEXT NOT NULL,
            source_id   TEXT NOT NULL,
            excerpt     TEXT NOT NULL DEFAULT '',
            at          INTEGER,
            created_at  INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE UNIQUE INDEX ux_memory_sources ON memory_sources(memory_id, source_type, source_id)")
        try db.execute(sql: "CREATE INDEX ix_memory_sources_src ON memory_sources(source_type, source_id)")

        try db.execute(sql: """
        CREATE TABLE memory_versions (
            id            TEXT PRIMARY KEY,
            memory_id     TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            version       INTEGER NOT NULL,
            title         TEXT NOT NULL DEFAULT '',
            content       TEXT NOT NULL,
            change_reason TEXT NOT NULL DEFAULT '',
            changed_by    TEXT NOT NULL,
            source_kind   TEXT NOT NULL DEFAULT 'real_interaction',
            created_at    INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE UNIQUE INDEX ux_memory_versions ON memory_versions(memory_id, version)")

        try db.execute(sql: """
        CREATE TABLE memory_links (
            id             TEXT PRIMARY KEY,
            from_memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            to_memory_id   TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            relation       TEXT NOT NULL,
            note           TEXT NOT NULL DEFAULT '',
            confidence     REAL NOT NULL DEFAULT 0.5,
            created_at     INTEGER NOT NULL,
            CHECK (from_memory_id <> to_memory_id)
        )
        """)
        try db.execute(sql: "CREATE UNIQUE INDEX ux_memory_links ON memory_links(from_memory_id, to_memory_id, relation)")
        try db.execute(sql: "CREATE INDEX ix_memory_links_to ON memory_links(to_memory_id)")

        try db.execute(sql: """
        CREATE TABLE memory_embeddings (
            owner_type TEXT NOT NULL,
            owner_id   TEXT NOT NULL,
            model      TEXT NOT NULL,
            dim        INTEGER NOT NULL,
            vector     BLOB NOT NULL,
            norm       REAL NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (owner_type, owner_id, model)
        )
        """)

        try db.execute(sql: """
        CREATE TABLE memory_recalls (
            id              TEXT PRIMARY KEY,
            memory_id       TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            at              INTEGER NOT NULL,
            conversation_id TEXT,
            message_id      TEXT,
            reason          TEXT NOT NULL DEFAULT 'retrieval',
            score           REAL NOT NULL DEFAULT 0,
            used_in_prompt  INTEGER NOT NULL DEFAULT 1
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_memory_recalls_mem ON memory_recalls(memory_id, at)")

        // L2 情景
        try db.execute(sql: """
        CREATE TABLE episodes (
            id                TEXT PRIMARY KEY,
            scope             TEXT NOT NULL,
            title             TEXT NOT NULL,
            summary           TEXT NOT NULL DEFAULT '',
            started_at        INTEGER NOT NULL,
            ended_at          INTEGER,
            time_precision    TEXT NOT NULL DEFAULT 'day',
            participants_json TEXT NOT NULL DEFAULT '[]',
            emotion_json      TEXT NOT NULL DEFAULT '{}',
            importance        REAL NOT NULL DEFAULT 0.5,
            confidence        REAL NOT NULL DEFAULT 0.5,
            source_kind       TEXT NOT NULL DEFAULT 'real_interaction',
            status            TEXT NOT NULL DEFAULT 'active',
            created_at        INTEGER NOT NULL,
            updated_at        INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_episodes_scope_time ON episodes(scope, started_at)")

        try db.execute(sql: """
        CREATE TABLE episode_memories (
            episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
            memory_id  TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            role       TEXT NOT NULL DEFAULT 'detail',
            PRIMARY KEY (episode_id, memory_id)
        )
        """)

        // L3 语义
        try db.execute(sql: """
        CREATE TABLE entities (
            id              TEXT PRIMARY KEY,
            kind            TEXT NOT NULL,
            name            TEXT NOT NULL,
            normalized_name TEXT NOT NULL,
            aliases_json    TEXT NOT NULL DEFAULT '[]',
            created_at      INTEGER NOT NULL,
            updated_at      INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE UNIQUE INDEX ux_entities ON entities(kind, normalized_name)")

        try db.execute(sql: """
        CREATE TABLE entity_facts (
            id               TEXT PRIMARY KEY,
            entity_id        TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            attribute        TEXT NOT NULL,
            value            TEXT NOT NULL,
            valid_from       INTEGER,
            valid_to         INTEGER,
            confidence       REAL NOT NULL DEFAULT 0.6,
            epistemic_status TEXT NOT NULL DEFAULT 'observed',
            source_kind      TEXT NOT NULL DEFAULT 'real_interaction',
            memory_id        TEXT REFERENCES memories(id) ON DELETE SET NULL,
            status           TEXT NOT NULL DEFAULT 'active',
            created_at       INTEGER NOT NULL,
            updated_at       INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_entity_facts_entity ON entity_facts(entity_id, attribute, status)")

        // L4 程序
        try db.execute(sql: """
        CREATE TABLE procedural_memories (
            id                TEXT PRIMARY KEY,
            scope             TEXT NOT NULL DEFAULT 'shared',
            category          TEXT NOT NULL,
            rule              TEXT NOT NULL,
            trigger_condition TEXT NOT NULL DEFAULT '',
            examples_json     TEXT NOT NULL DEFAULT '[]',
            confidence        REAL NOT NULL DEFAULT 0.6,
            weight            REAL NOT NULL DEFAULT 1.0,
            source_kind       TEXT NOT NULL DEFAULT 'model_reflection',
            version           INTEGER NOT NULL DEFAULT 1,
            status            TEXT NOT NULL DEFAULT 'active',
            created_at        INTEGER NOT NULL,
            updated_at        INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_procedural_scope_cat ON procedural_memories(scope, category, status)")

        // L5 反思
        try db.execute(sql: """
        CREATE TABLE reflections (
            id               TEXT PRIMARY KEY,
            scope            TEXT NOT NULL DEFAULT 'self',
            kind             TEXT NOT NULL,
            subject          TEXT NOT NULL DEFAULT '',
            content          TEXT NOT NULL,
            conclusion       TEXT NOT NULL DEFAULT '',
            input_refs_json  TEXT NOT NULL DEFAULT '[]',
            confidence       REAL NOT NULL DEFAULT 0.5,
            epistemic_status TEXT NOT NULL DEFAULT 'inferred',
            source_kind      TEXT NOT NULL DEFAULT 'model_reflection',
            status           TEXT NOT NULL DEFAULT 'active',
            superseded_by    TEXT REFERENCES reflections(id),
            created_at       INTEGER NOT NULL,
            updated_at       INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_reflections_scope_time ON reflections(scope, created_at)")

        // L6 时序知识图谱
        try db.execute(sql: """
        CREATE TABLE kg_nodes (
            id         TEXT PRIMARY KEY,
            kind       TEXT NOT NULL,
            label      TEXT NOT NULL,
            ref_type   TEXT,
            ref_id     TEXT,
            props_json TEXT NOT NULL DEFAULT '{}',
            created_at INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_kg_nodes_kind ON kg_nodes(kind, label)")
        try db.execute(sql: "CREATE UNIQUE INDEX ux_kg_nodes_ref ON kg_nodes(ref_type, ref_id) WHERE ref_id IS NOT NULL")

        try db.execute(sql: """
        CREATE TABLE kg_edges (
            id           TEXT PRIMARY KEY,
            from_node_id TEXT NOT NULL REFERENCES kg_nodes(id) ON DELETE CASCADE,
            to_node_id   TEXT NOT NULL REFERENCES kg_nodes(id) ON DELETE CASCADE,
            relation     TEXT NOT NULL,
            valid_from   INTEGER,
            valid_to     INTEGER,
            confidence   REAL NOT NULL DEFAULT 0.6,
            source_kind  TEXT NOT NULL DEFAULT 'real_interaction',
            source_ref   TEXT,
            props_json   TEXT NOT NULL DEFAULT '{}',
            created_at   INTEGER NOT NULL,
            CHECK (from_node_id <> to_node_id)
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_kg_edges_from ON kg_edges(from_node_id, relation)")
        try db.execute(sql: "CREATE INDEX ix_kg_edges_to ON kg_edges(to_node_id, relation)")
        try db.execute(sql: "CREATE INDEX ix_kg_edges_time ON kg_edges(valid_from, valid_to)")

        // 变化检测 / 未完成话题 / 工作记忆 / 任务队列
        try db.execute(sql: """
        CREATE TABLE change_events (
            id            TEXT PRIMARY KEY,
            scope         TEXT NOT NULL,
            subject_type  TEXT NOT NULL,
            subject_ref   TEXT NOT NULL,
            dimension     TEXT NOT NULL,
            from_value    TEXT NOT NULL DEFAULT '',
            to_value      TEXT NOT NULL DEFAULT '',
            detected_at   INTEGER NOT NULL,
            confidence    REAL NOT NULL DEFAULT 0.5,
            evidence_json TEXT NOT NULL DEFAULT '[]',
            status        TEXT NOT NULL DEFAULT 'open'
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_change_events_time ON change_events(scope, detected_at)")

        try db.execute(sql: """
        CREATE TABLE open_topics (
            id              TEXT PRIMARY KEY,
            scope           TEXT NOT NULL DEFAULT 'shared',
            title           TEXT NOT NULL,
            summary         TEXT NOT NULL DEFAULT '',
            status          TEXT NOT NULL DEFAULT 'open',
            priority        INTEGER NOT NULL DEFAULT 2,
            opened_at       INTEGER NOT NULL,
            due_at          INTEGER,
            last_touched_at INTEGER NOT NULL,
            closed_reason   TEXT,
            evidence_json   TEXT NOT NULL DEFAULT '[]'
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_open_topics_status ON open_topics(status, priority, due_at)")

        try db.execute(sql: """
        CREATE TABLE working_memory_snapshots (
            id              TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            built_at        INTEGER NOT NULL,
            expires_at      INTEGER NOT NULL,
            token_estimate  INTEGER NOT NULL DEFAULT 0,
            message_count   INTEGER NOT NULL DEFAULT 0,
            payload_json    TEXT NOT NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_wm_conv ON working_memory_snapshots(conversation_id, built_at)")

        try db.execute(sql: """
        CREATE TABLE memory_jobs (
            id              TEXT PRIMARY KEY,
            kind            TEXT NOT NULL,
            target_type     TEXT,
            target_id       TEXT,
            scope           TEXT,
            payload_json    TEXT NOT NULL DEFAULT '{}',
            status          TEXT NOT NULL DEFAULT 'pending',
            priority        INTEGER NOT NULL DEFAULT 5,
            attempts        INTEGER NOT NULL DEFAULT 0,
            max_attempts    INTEGER NOT NULL DEFAULT 3,
            scheduled_at    INTEGER NOT NULL,
            started_at      INTEGER,
            finished_at     INTEGER,
            error           TEXT,
            idempotency_key TEXT NOT NULL,
            created_at      INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE UNIQUE INDEX ux_memory_jobs_idem ON memory_jobs(idempotency_key)")
        try db.execute(sql: "CREATE INDEX ix_memory_jobs_run ON memory_jobs(status, scheduled_at, priority)")

        // 分类历史（D2）
        try db.execute(sql: """
        CREATE TABLE memory_classification_history (
            id              TEXT PRIMARY KEY,
            memory_id       TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            from_scope      TEXT,
            to_scope        TEXT NOT NULL,
            from_status     TEXT,
            to_status       TEXT NOT NULL,
            reason          TEXT NOT NULL DEFAULT '',
            evidence_json   TEXT NOT NULL DEFAULT '[]',
            decided_by      TEXT NOT NULL,
            import_batch_id TEXT,
            created_at      INTEGER NOT NULL,
            reverted_at     INTEGER,
            reverted_by     TEXT
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_class_history_memory ON memory_classification_history(memory_id, created_at)")
        try db.execute(sql: "CREATE INDEX ix_class_history_batch ON memory_classification_history(import_batch_id, created_at)")

        // 旧表扩展：proposals / persona_items / proactive_*
        let proposalColumns = [
            "ALTER TABLE proposals ADD COLUMN scope TEXT",
            "ALTER TABLE proposals ADD COLUMN risk TEXT NOT NULL DEFAULT 'medium'",
            "ALTER TABLE proposals ADD COLUMN expires_at INTEGER",
            "ALTER TABLE proposals ADD COLUMN decided_by TEXT"
        ]
        for statement in proposalColumns { try db.execute(sql: statement) }

        let personaColumns = [
            "ALTER TABLE persona_items ADD COLUMN tier TEXT",
            "ALTER TABLE persona_items ADD COLUMN tier_status TEXT NOT NULL DEFAULT 'pending'",
            "ALTER TABLE persona_items ADD COLUMN tier_source TEXT",
            "ALTER TABLE persona_items ADD COLUMN tier_conflict TEXT",
            "ALTER TABLE persona_items ADD COLUMN tier_evidence TEXT",
            "ALTER TABLE persona_items ADD COLUMN original_tier TEXT",
            "ALTER TABLE persona_items ADD COLUMN tier_migrated_at INTEGER",
            "ALTER TABLE persona_items ADD COLUMN tier_batch_id TEXT",
            "ALTER TABLE persona_items ADD COLUMN evidence_memory_id TEXT",
            "ALTER TABLE persona_items ADD COLUMN status TEXT NOT NULL DEFAULT 'active'"
        ]
        for statement in personaColumns { try db.execute(sql: statement) }

        try db.execute(sql: """
        CREATE TABLE persona_item_tier_history (
            id            TEXT PRIMARY KEY,
            item_id       TEXT NOT NULL REFERENCES persona_items(id) ON DELETE CASCADE,
            from_tier     TEXT,
            to_tier       TEXT NOT NULL,
            from_status   TEXT,
            to_status     TEXT NOT NULL,
            reason        TEXT NOT NULL,
            evidence_json TEXT NOT NULL DEFAULT '{}',
            decided_by    TEXT NOT NULL,
            batch_id      TEXT,
            created_at    INTEGER NOT NULL,
            reverted_at   INTEGER,
            reverted_by   TEXT
        )
        """)
        try db.execute(sql: "CREATE INDEX ix_tier_history_item ON persona_item_tier_history(item_id, created_at)")

        let intentColumns = [
            "ALTER TABLE proactive_intents ADD COLUMN priority INTEGER NOT NULL DEFAULT 3",
            "ALTER TABLE proactive_intents ADD COLUMN expires_at INTEGER",
            "ALTER TABLE proactive_intents ADD COLUMN dedupe_key TEXT",
            "ALTER TABLE proactive_intents ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'reflection'",
            "ALTER TABLE proactive_intents ADD COLUMN evidence_ok INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE proactive_messages ADD COLUMN priority INTEGER NOT NULL DEFAULT 3",
            "ALTER TABLE proactive_messages ADD COLUMN expires_at INTEGER",
            "ALTER TABLE proactive_messages ADD COLUMN dedupe_key TEXT",
            "ALTER TABLE proactive_messages ADD COLUMN message_id TEXT",
            "ALTER TABLE proactive_messages ADD COLUMN sent_at INTEGER"
        ]
        for statement in intentColumns { try db.execute(sql: statement) }
    }

    // MARK: - 5. FTS5

    private static func createFullTextSearch(_ db: Database) throws {
        // 不挂 external content：中文 bigram 需要在应用层生成
        try db.execute(sql: """
        CREATE VIRTUAL TABLE memory_fts USING fts5(
            memory_id UNINDEXED,
            scope UNINDEXED,
            text_bigram,
            tokenize = 'unicode61'
        )
        """)
    }

    // MARK: - 6. 索引与视图

    private static func createIndexesAndViews(_ db: Database) throws {
        let indexes = [
            "CREATE INDEX ix_memories_scope_layer ON memories(scope, layer, status)",
            "CREATE INDEX ix_memories_scope_time ON memories(scope, first_seen_at)",
            "CREATE INDEX ix_memories_heat ON memories(heat, last_recalled_at)",
            "CREATE INDEX ix_memories_entity ON memories(subject_entity_id)",
            "CREATE INDEX ix_memories_classify ON memories(classification_status, import_batch_id)",
            """
            CREATE UNIQUE INDEX ux_memories_dedupe
              ON memories(scope, dedupe_key)
              WHERE dedupe_key IS NOT NULL AND deleted_at IS NULL
            """,
            """
            CREATE UNIQUE INDEX ux_memories_origin
              ON memories(import_batch_id, original_external_id)
              WHERE original_external_id IS NOT NULL
            """,
            "CREATE INDEX ix_persona_items_tier ON persona_items(persona_id, tier, tier_status)",
            """
            CREATE UNIQUE INDEX ux_proactive_dedupe
              ON proactive_messages(dedupe_key) WHERE dedupe_key IS NOT NULL
            """
        ]
        for statement in indexes { try db.execute(sql: statement) }

        try db.execute(sql: """
        CREATE VIEW v_memory_user AS
          SELECT * FROM memories WHERE scope = 'user' AND status <> 'deleted'
        """)
        try db.execute(sql: """
        CREATE VIEW v_memory_shared AS
          SELECT * FROM memories WHERE scope = 'shared' AND status <> 'deleted'
        """)
        try db.execute(sql: """
        CREATE VIEW v_memory_self AS
          SELECT * FROM memories WHERE scope = 'self' AND status <> 'deleted'
        """)
        try db.execute(sql: """
        CREATE VIEW v_memory_stats AS
        SELECT m.scope,
               m.layer,
               COUNT(*) AS total,
               SUM(CASE WHEN m.status = 'active' THEN 1 ELSE 0 END) AS active_count,
               SUM(CASE WHEN m.status = 'pending_confirm' THEN 1 ELSE 0 END) AS pending_count,
               SUM(CASE WHEN m.status = 'disputed' THEN 1 ELSE 0 END) AS disputed_count,
               SUM(CASE WHEN m.heat = 'hot' THEN 1 ELSE 0 END) AS hot_count,
               MAX(m.last_recalled_at) AS last_recalled_at
        FROM memories m
        WHERE m.status <> 'deleted'
        GROUP BY m.scope, m.layer
        """)
    }

    // MARK: - 7. 回填

    private static func backfill(_ db: Database, now: Int64) throws {
        // 时间列：旧表只有 first_seen_at
        try db.execute(sql: "UPDATE memories SET created_at = first_seen_at WHERE created_at = 0")
        try db.execute(sql: "UPDATE memories SET updated_at = first_seen_at WHERE updated_at = 0")
        try db.execute(sql: "UPDATE memories SET updated_at = created_at WHERE updated_at = 0")

        // 历史数据默认：scope=shared（仅暂存）、classification_status=pending（列默认值已填）
        // 重要度映射（D-A）：只写有把握的；解析不了的一律 NULL，绝不写 0.5
        let rows = try MemoryImportanceRow.fetchAll(db, sql: "SELECT id, importance FROM memories")
        for row in rows {
            let id = row.id
            let raw = row.importance
            let mapped = Self.mapImportance(raw)

            try db.execute(
                sql: """
                UPDATE memories
                   SET importance_score = ?, importance_source = ?, importance_source_at = ?
                 WHERE id = ?
                """,
                arguments: [mapped.score, mapped.source, now, id]
            )

            if mapped.source == "unparsed" {
                try db.execute(
                    sql: """
                    INSERT INTO memory_importance_history
                        (id, memory_id, from_source, to_source, from_score, to_score, reason, evidence, decided_by, created_at)
                    VALUES (?, ?, NULL, ?, NULL, NULL, 'parse_failed', ?, 'migration', ?)
                    """,
                    arguments: [UUID().uuidString, id, mapped.source, raw, now]
                )
            }
        }

        // FTS 回填：bigram 由应用层生成
        try db.execute(sql: "DELETE FROM memory_fts")
        let ftsRows = try MemoryTextRow.fetchAll(db, sql: "SELECT id, scope, title, content FROM memories ORDER BY id")
        for row in ftsRows {
            try db.execute(
                sql: "INSERT INTO memory_fts (memory_id, scope, text_bigram) VALUES (?, ?, ?)",
                arguments: [row.id, row.scope, Self.bigram(row.title + " " + row.content)]
            )
        }
    }

    // MARK: - 7b. 人格层级回填（D-B）

    /// 三值映射：只按 `personas.kind` 判定；`is_locked=1 且 kind=outer` 保留 outer 并记录冲突。
    static func tierMapping(
        hasPersona: Bool,
        kind: String?,
        isLocked: Int?
    ) -> (tier: String, status: String, source: String, conflict: String?, evidence: String) {
        guard hasPersona else {
            return ("pending", "pending", "orphan", nil, "{\"reason\":\"persona_missing\"}")
        }
        switch kind {
        case "core":
            return ("core", "core", "kind_core", nil, "{\"kind\":\"core\"}")
        case "outer":
            if isLocked == 1 {
                return ("outer", "outer", "kind_outer", "locked_outer", "{\"kind\":\"outer\",\"is_locked\":1}")
            }
            return ("outer", "outer", "kind_outer", nil, "{\"kind\":\"outer\"}")
        default:
            return ("pending", "pending", "invalid_kind", "invalid_kind", "{\"kind\":null}")
        }
    }

    private static func backfillPersonaTier(_ db: Database, now: Int64, batch: String) throws {
        let rows = try PersonaItemRow.fetchAll(db, sql: """
        SELECT i.id AS item_id, p.id AS persona_id, p.kind AS kind, p.is_locked AS is_locked
          FROM persona_items i
          LEFT JOIN personas p ON p.id = i.persona_id
        """)

        for row in rows {
            let mapped = Self.tierMapping(
                hasPersona: row.personaId != nil,
                kind: row.kind,
                isLocked: row.isLocked
            )
            try db.execute(
                sql: """
                UPDATE persona_items
                   SET tier = ?, tier_status = ?, tier_source = ?, tier_conflict = ?,
                       tier_evidence = ?, tier_migrated_at = ?, tier_batch_id = ?
                 WHERE id = ?
                """,
                arguments: [mapped.tier, mapped.status, mapped.source, mapped.conflict, mapped.evidence, now, batch, row.itemId]
            )
            try db.execute(
                sql: """
                INSERT INTO persona_item_tier_history
                    (id, item_id, from_tier, to_tier, from_status, to_status, reason, evidence_json, decided_by, batch_id, created_at)
                VALUES (?, ?, NULL, ?, NULL, ?, 'migration', ?, 'migration', ?, ?)
                """,
                arguments: [UUID().uuidString, row.itemId, mapped.tier, mapped.status, mapped.evidence, batch, now]
            )
        }
    }

    private static func personaFingerprint(_ db: Database) throws -> String {
        let rows = try PersonaContentRow.fetchAll(db, sql: "SELECT id, value FROM persona_items ORDER BY id")
        var buffer = ""
        for row in rows {
            buffer += row.id + "\u{1F}" + row.value + "\u{1E}"
        }
        return SHA256.hash(buffer)
    }

    /// 重要性映射（D-A 冻结口径）
    /// - high/normal/low → 0.80/0.50/0.30，来源 `legacy_text`
    /// - 可解析且落在 [0,1] 的数字 → 原值（2 位），来源 `legacy_numeric`
    /// - 其余（含 "80"、乱码）→ NULL，来源 `unparsed`，**不赋分、不写回**
    static func mapImportance(_ raw: String) -> (score: Double?, source: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch text {
        case "high", "重要":
            return (0.80, "legacy_text")
        case "normal", "一般":
            return (0.50, "legacy_text")
        case "low", "不重要":
            return (0.30, "legacy_text")
        default:
            break
        }
        if let value = Double(text), value.isFinite, value >= 0, value <= 1 {
            return ((value * 100).rounded() / 100, "legacy_numeric")
        }
        return (nil, "unparsed")
    }

    /// 中文/字母数字 → 检索词：连续汉字切重叠二元组，连续字母数字整体保留
    static func bigram(_ text: String) -> String {
        var tokens: [String] = []
        var cjkRun: [Character] = []
        var wordRun: [Character] = []

        func flushCJK() {
            if cjkRun.count == 1 {
                tokens.append(String(cjkRun[0]))
            } else if cjkRun.count > 1 {
                for index in 0..<(cjkRun.count - 1) {
                    tokens.append(String(cjkRun[index...(index + 1)]))
                }
            }
            cjkRun.removeAll()
        }
        func flushWord() {
            if !wordRun.isEmpty {
                tokens.append(String(wordRun).lowercased())
                wordRun.removeAll()
            }
        }

        for character in text {
            if character.isCJK {
                flushWord()
                cjkRun.append(character)
            } else if character.isLetter || character.isNumber {
                flushCJK()
                wordRun.append(character)
            } else {
                flushCJK()
                flushWord()
            }
        }
        flushCJK()
        flushWord()
        return tokens.joined(separator: " ")
    }

    // MARK: - 8. 校验

    private static func contentFingerprint(_ db: Database) throws -> String {
        let rows = try MemoryContentRow.fetchAll(db, sql: "SELECT id, content FROM memories ORDER BY id")
        var buffer = ""
        for row in rows {
            buffer += row.id + "\u{1F}" + row.content + "\u{1E}"
        }
        return SHA256.hash(buffer)
    }

    private static func validate(
        _ db: Database,
        memoriesBefore: Int,
        messagesBefore: Int,
        contentHashBefore: String,
        personaBefore: Int,
        personaHashBefore: String
    ) throws {
        let memoriesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories") ?? -1
        guard memoriesAfter == memoriesBefore else {
            throw DFError.database("memories 行数变化：\(memoriesBefore) → \(memoriesAfter)")
        }
        let messagesAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? -1
        guard messagesAfter == messagesBefore else {
            throw DFError.database("messages 行数变化：\(messagesBefore) → \(messagesAfter)")
        }
        let hashAfter = try contentFingerprint(db)
        guard hashAfter == contentHashBefore else {
            throw DFError.database("memories.content 内容指纹变化，迁移被拒绝")
        }

        let ftsCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM memory_fts") ?? -1
        guard ftsCount == memoriesAfter else {
            throw DFError.database("FTS 行数(\(ftsCount)) 与记忆行数(\(memoriesAfter)) 不一致")
        }

        // NULL 数量必须等于 unparsed 数量（禁止写回 0.5）
        let nullScores = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories WHERE importance_score IS NULL") ?? -1
        let unparsed = try Int.fetchOne(db, sql: "SELECT count(*) FROM memories WHERE importance_source = 'unparsed'") ?? -1
        guard nullScores == unparsed else {
            throw DFError.database("importance_source 与 importance_score 不一致：unparsed=\(unparsed)，NULL=\(nullScores)")
        }

        let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quick.lowercased() == "ok" else {
            throw DFError.database("迁移后 quick_check 失败：\(quick)")
        }

        // 人格：行数与内容指纹必须完全不变，且每条都必须有层级
        let personaAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM persona_items") ?? -1
        guard personaAfter == personaBefore else {
            throw DFError.database("persona_items 行数变化：\(personaBefore) → \(personaAfter)")
        }
        let personaHashAfter = try personaFingerprint(db)
        guard personaHashAfter == personaHashBefore else {
            throw DFError.database("persona_items.value 内容指纹变化，迁移被拒绝")
        }
        let untiered = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM persona_items WHERE tier IS NULL OR tier_status IS NULL"
        ) ?? -1
        guard untiered == 0 else {
            throw DFError.database("仍有 \(untiered) 条人格条目未完成层级回填")
        }
    }
}

private extension Character {
    /// 是否为 CJK 汉字（够用即可，不做完整 Unicode 分类）
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}

// MARK: - 内部查询模型（避免依赖 Row 的动态取值）

private struct ColumnInfoRow: Decodable, FetchableRecord {
    var name: String
}

private struct MemoryImportanceRow: Decodable, FetchableRecord {
    var id: String
    var importance: String
}

private struct MemoryTextRow: Decodable, FetchableRecord {
    var id: String
    var scope: String
    var title: String
    var content: String
}

private struct MemoryContentRow: Decodable, FetchableRecord {
    var id: String
    var content: String
}

private struct PersonaItemRow: Decodable, FetchableRecord {
    var itemId: String
    var personaId: String?
    var kind: String?
    var isLocked: Int?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case personaId = "persona_id"
        case kind
        case isLocked = "is_locked"
    }
}

private struct PersonaContentRow: Decodable, FetchableRecord {
    var id: String
    var value: String
}
