/// 数据库表结构（对齐 SwiftUI 版 v1_phase1 + v2_memory + v8 + v14 的最终列形态）。
///
/// 说明：
/// - Flutter 版为全新安装，直接建最终态结构；`user_version` 记录结构版本号，
///   未来新增列通过 [Migrations.onUpgrade] 追加，不破坏旧数据；
/// - 列名、类型、默认值与旧版保持一致，使旧版备份快照可以直接导入恢复；
/// - 旧版按 15 个迁移分步建表，这里合并为"最终态一次性建表"，
///   ALTER 追加列直接并入 CREATE 语句，语义等价；
/// - FTS5 虚表不挂 external content：中文 bigram 由应用层（[bigram]）生成。
library;

/// 当前结构版本
const int kSchemaVersion = 3;

const List<String> kSchemaStatements = <String>[
  // ── 聊天基础 ────────────────────────────────────────────────────────────

  // 会话
  'CREATE TABLE conversations ('
      'id TEXT PRIMARY KEY, '
      'title TEXT NOT NULL, '
      "kind TEXT NOT NULL DEFAULT 'main', "
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'archived_at INTEGER)',

  // 消息（含 v8 编辑/撤回/收藏列与 v14 重要标记列）
  'CREATE TABLE messages ('
      'id TEXT PRIMARY KEY, '
      'client_uuid TEXT NOT NULL UNIQUE, '
      'conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, '
      'role TEXT NOT NULL, '
      'kind TEXT NOT NULL, '
      "text TEXT NOT NULL DEFAULT '', "
      'status TEXT NOT NULL, '
      'origin TEXT NOT NULL, '
      'reply_to_id TEXT, '
      'created_at INTEGER NOT NULL, '
      'sent_at INTEGER, '
      'model_config_id TEXT, '
      'emotion_state_id TEXT, '
      'deleted_at INTEGER, '
      'group_id TEXT, '
      'seq_in_group INTEGER, '
      'edited_at INTEGER, '
      'edit_count INTEGER NOT NULL DEFAULT 0, '
      'revoked_at INTEGER, '
      'revoke_reason TEXT, '
      'is_favorite INTEGER NOT NULL DEFAULT 0, '
      'is_important INTEGER NOT NULL DEFAULT 0, '
      'important_at INTEGER)',
  'CREATE INDEX ix_messages_conv_time ON messages(conversation_id, created_at)',
  'CREATE INDEX ix_messages_conv_status ON messages(conversation_id, status)',

  // 人格（含 v2 的 tier 分层扩展列）
  'CREATE TABLE personas ('
      'id TEXT PRIMARY KEY, '
      'kind TEXT NOT NULL, '
      'name TEXT NOT NULL, '
      'is_locked INTEGER NOT NULL DEFAULT 0, '
      'current_version INTEGER NOT NULL DEFAULT 1, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL)',
  'CREATE TABLE persona_items ('
      'id TEXT PRIMARY KEY, '
      'persona_id TEXT NOT NULL REFERENCES personas(id) ON DELETE CASCADE, '
      'section TEXT NOT NULL, '
      'key TEXT NOT NULL, '
      'value TEXT NOT NULL, '
      'confidence REAL NOT NULL DEFAULT 1.0, '
      'weight REAL NOT NULL DEFAULT 1.0, '
      "source TEXT NOT NULL DEFAULT 'user', "
      'updated_at INTEGER NOT NULL, '
      'tier TEXT, '
      "tier_status TEXT NOT NULL DEFAULT 'pending', "
      'tier_source TEXT, '
      'tier_conflict TEXT, '
      'tier_evidence TEXT, '
      'original_tier TEXT, '
      'tier_migrated_at INTEGER, '
      'tier_batch_id TEXT, '
      'evidence_memory_id TEXT, '
      "status TEXT NOT NULL DEFAULT 'active')",
  'CREATE INDEX ix_persona_items_persona ON persona_items(persona_id)',
  'CREATE INDEX ix_persona_items_tier ON persona_items(persona_id, tier, tier_status)',
  'CREATE TABLE persona_versions ('
      'id TEXT PRIMARY KEY, '
      'persona_id TEXT NOT NULL REFERENCES personas(id) ON DELETE CASCADE, '
      'version INTEGER NOT NULL, '
      'snapshot_json TEXT NOT NULL, '
      'change_reason TEXT NOT NULL, '
      'changed_by TEXT NOT NULL, '
      'created_at INTEGER NOT NULL)',
  'CREATE UNIQUE INDEX ux_persona_versions ON persona_versions(persona_id, version)',
  'CREATE TABLE persona_item_tier_history ('
      'id TEXT PRIMARY KEY, '
      'item_id TEXT NOT NULL REFERENCES persona_items(id) ON DELETE CASCADE, '
      'from_tier TEXT, '
      'to_tier TEXT NOT NULL, '
      'from_status TEXT, '
      'to_status TEXT NOT NULL, '
      'reason TEXT NOT NULL, '
      "evidence_json TEXT NOT NULL DEFAULT '{}', "
      'decided_by TEXT NOT NULL, '
      'batch_id TEXT, '
      'created_at INTEGER NOT NULL, '
      'reverted_at INTEGER, '
      'reverted_by TEXT)',
  'CREATE INDEX ix_tier_history_item ON persona_item_tier_history(item_id, created_at)',

  // 模型配置（密钥不在此表，存安全存储）
  'CREATE TABLE model_configs ('
      'id TEXT PRIMARY KEY, '
      'name TEXT NOT NULL, '
      "provider_kind TEXT NOT NULL DEFAULT 'openaiCompatible', "
      'base_url TEXT NOT NULL, '
      'model_id TEXT NOT NULL, '
      'key_ref TEXT NOT NULL, '
      'is_default INTEGER NOT NULL DEFAULT 0, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL)',

  // 附件索引（P1 图片/语音使用）
  'CREATE TABLE attachments ('
      'id TEXT PRIMARY KEY, '
      'sha256 TEXT NOT NULL UNIQUE, '
      'kind TEXT NOT NULL, '
      'rel_path TEXT NOT NULL, '
      'byte_size INTEGER NOT NULL, '
      'mime TEXT NOT NULL, '
      'created_at INTEGER NOT NULL)',
  'CREATE TABLE message_attachments ('
      'message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE, '
      'attachment_id TEXT NOT NULL REFERENCES attachments(id) ON DELETE CASCADE, '
      'sort INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY (message_id, attachment_id))',

  // 键值设置
  'CREATE TABLE settings ('
      'key TEXT PRIMARY KEY, '
      'value TEXT NOT NULL)',

  // AI 变更提案（v1 基础 + v2 扩展列）
  'CREATE TABLE proposals ('
      'id TEXT PRIMARY KEY, '
      'kind TEXT NOT NULL, '
      'payload_json TEXT NOT NULL, '
      'reason TEXT, '
      'evidence_json TEXT, '
      "status TEXT NOT NULL DEFAULT 'pending', "
      'created_at INTEGER NOT NULL, '
      'resolved_at INTEGER, '
      'resolution_note TEXT, '
      'scope TEXT, '
      "risk TEXT NOT NULL DEFAULT 'medium', "
      'expires_at INTEGER, '
      'decided_by TEXT)',

  // 时间线事件
  'CREATE TABLE timeline_events ('
      'id TEXT PRIMARY KEY, '
      'kind TEXT NOT NULL, '
      'title TEXT NOT NULL, '
      'summary TEXT, '
      'occurred_at INTEGER NOT NULL, '
      "precision TEXT NOT NULL DEFAULT 'day', "
      "importance TEXT NOT NULL DEFAULT 'normal', "
      'refs_json TEXT)',

  // 主动消息（v1 基础 + v2 扩展列）
  'CREATE TABLE proactive_intents ('
      'id TEXT PRIMARY KEY, '
      'created_at INTEGER NOT NULL, '
      'type TEXT NOT NULL, '
      'reason TEXT, '
      'evidence_json TEXT, '
      'confidence REAL NOT NULL DEFAULT 0.5, '
      "status TEXT NOT NULL DEFAULT 'new', "
      'priority INTEGER NOT NULL DEFAULT 3, '
      'expires_at INTEGER, '
      'dedupe_key TEXT, '
      "source_kind TEXT NOT NULL DEFAULT 'reflection', "
      'evidence_ok INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE proactive_messages ('
      'id TEXT PRIMARY KEY, '
      'intent_id TEXT, '
      'planned_at INTEGER NOT NULL, '
      'text TEXT NOT NULL, '
      'is_voice INTEGER NOT NULL DEFAULT 0, '
      "status TEXT NOT NULL DEFAULT 'planned', "
      'suppress_reason TEXT, '
      'notification_id TEXT, '
      'resolved_at INTEGER, '
      'priority INTEGER NOT NULL DEFAULT 3, '
      'expires_at INTEGER, '
      'dedupe_key TEXT, '
      'message_id TEXT, '
      'sent_at INTEGER)',
  'CREATE UNIQUE INDEX ux_proactive_dedupe '
      'ON proactive_messages(dedupe_key) WHERE dedupe_key IS NOT NULL',

  // ── 记忆层（v2_memory 最终态）───────────────────────────────────────────

  // 三套记忆注册 + 预置数据
  'CREATE TABLE memory_scopes ('
      'id TEXT PRIMARY KEY, '
      'display_name TEXT NOT NULL, '
      "description TEXT NOT NULL DEFAULT '', "
      "policy_json TEXT NOT NULL DEFAULT '{}', "
      'created_at INTEGER NOT NULL)',
  'INSERT INTO memory_scopes (id, display_name, description, policy_json, created_at) VALUES '
      '(\'user\', \'用户记忆\', \'关于用户的稳定事实、兴趣、偏好、习惯、观点变化\', \'{"scope_weight":0.95,"decay_tau_days":730}\', 0), '
      '(\'shared\', \'共同记忆\', \'双方真实发生过的互动、共同经历、关系与时间线\', \'{"scope_weight":1.0,"decay_tau_days":3650}\', 0), '
      '(\'self\', \'自身记忆\', \'大肥鱼自己的兴趣、想法、反思、计划与阶段性总结\', \'{"scope_weight":0.9,"decay_tau_days":365}\', 0)',

  // memories：v1 基表 + v2 扩展列（合并为最终态）
  'CREATE TABLE memories ('
      'id TEXT PRIMARY KEY, '
      'type TEXT NOT NULL, '
      'title TEXT NOT NULL, '
      'content TEXT NOT NULL, '
      "importance TEXT NOT NULL DEFAULT 'normal', "
      'salience REAL NOT NULL DEFAULT 0.5, '
      'confidence REAL NOT NULL DEFAULT 0.5, '
      'valid_from INTEGER, '
      'valid_to INTEGER, '
      "status TEXT NOT NULL DEFAULT 'active', "
      'first_seen_at INTEGER NOT NULL, '
      'last_recalled_at INTEGER, '
      'recall_count INTEGER NOT NULL DEFAULT 0, '
      "scope TEXT NOT NULL DEFAULT 'shared', "
      "layer TEXT NOT NULL DEFAULT 'semantic', "
      "category TEXT NOT NULL DEFAULT 'fact', "
      "source_kind TEXT NOT NULL DEFAULT 'real_interaction', "
      "epistemic_status TEXT NOT NULL DEFAULT 'observed', "
      'version INTEGER NOT NULL DEFAULT 1, '
      'subject_entity_id TEXT, '
      'dedupe_key TEXT, '
      "heat TEXT NOT NULL DEFAULT 'warm', "
      'archived_at INTEGER, '
      'deleted_at INTEGER, '
      'created_at INTEGER NOT NULL DEFAULT 0, '
      'updated_at INTEGER NOT NULL DEFAULT 0, '
      'importance_score REAL, '
      "importance_source TEXT NOT NULL DEFAULT 'unparsed', "
      'importance_source_at INTEGER, '
      "classification_status TEXT NOT NULL DEFAULT 'pending', "
      'original_external_id TEXT, '
      'original_content TEXT, '
      'original_created_at INTEGER, '
      'import_batch_id TEXT, '
      "classification_evidence_json TEXT NOT NULL DEFAULT '[]', "
      'classified_by TEXT, '
      'classified_at INTEGER)',
  'CREATE INDEX ix_memories_scope_layer ON memories(scope, layer, status)',
  'CREATE INDEX ix_memories_scope_time ON memories(scope, first_seen_at)',
  'CREATE INDEX ix_memories_heat ON memories(heat, last_recalled_at)',
  'CREATE INDEX ix_memories_entity ON memories(subject_entity_id)',
  'CREATE INDEX ix_memories_classify ON memories(classification_status, import_batch_id)',
  'CREATE UNIQUE INDEX ux_memories_dedupe '
      'ON memories(scope, dedupe_key) '
      'WHERE dedupe_key IS NOT NULL AND deleted_at IS NULL',
  'CREATE UNIQUE INDEX ux_memories_origin '
      'ON memories(import_batch_id, original_external_id) '
      'WHERE original_external_id IS NOT NULL',

  // 重要度变更历史
  'CREATE TABLE memory_importance_history ('
      'id TEXT PRIMARY KEY, '
      'memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE, '
      'from_source TEXT, '
      'to_source TEXT NOT NULL, '
      'from_score REAL, '
      'to_score REAL, '
      'reason TEXT NOT NULL, '
      'evidence TEXT, '
      'decided_by TEXT NOT NULL, '
      'created_at INTEGER NOT NULL)',
  'CREATE INDEX ix_importance_history_memory ON memory_importance_history(memory_id, created_at)',

  // 记忆来源
  'CREATE TABLE memory_sources ('
      'id TEXT PRIMARY KEY, '
      'memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE, '
      'source_type TEXT NOT NULL, '
      'source_id TEXT NOT NULL, '
      "excerpt TEXT NOT NULL DEFAULT '', "
      'at INTEGER, '
      'created_at INTEGER NOT NULL)',
  'CREATE UNIQUE INDEX ux_memory_sources ON memory_sources(memory_id, source_type, source_id)',
  'CREATE INDEX ix_memory_sources_src ON memory_sources(source_type, source_id)',

  // 记忆版本
  'CREATE TABLE memory_versions ('
      'id TEXT PRIMARY KEY, '
      'memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE, '
      'version INTEGER NOT NULL, '
      "title TEXT NOT NULL DEFAULT '', "
      'content TEXT NOT NULL, '
      "change_reason TEXT NOT NULL DEFAULT '', "
      'changed_by TEXT NOT NULL, '
      "source_kind TEXT NOT NULL DEFAULT 'real_interaction', "
      'created_at INTEGER NOT NULL)',
  'CREATE UNIQUE INDEX ux_memory_versions ON memory_versions(memory_id, version)',

  // 记忆关联（禁止自引用）
  'CREATE TABLE memory_links ('
      'id TEXT PRIMARY KEY, '
      'from_memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE, '
      'to_memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE, '
      'relation TEXT NOT NULL, '
      "note TEXT NOT NULL DEFAULT '', "
      'confidence REAL NOT NULL DEFAULT 0.5, '
      'created_at INTEGER NOT NULL, '
      'CHECK (from_memory_id <> to_memory_id))',
  'CREATE UNIQUE INDEX ux_memory_links ON memory_links(from_memory_id, to_memory_id, relation)',
  'CREATE INDEX ix_memory_links_to ON memory_links(to_memory_id)',

  // 向量嵌入（预留，本地版不启用检索）
  'CREATE TABLE memory_embeddings ('
      'owner_type TEXT NOT NULL, '
      'owner_id TEXT NOT NULL, '
      'model TEXT NOT NULL, '
      'dim INTEGER NOT NULL, '
      'vector BLOB NOT NULL, '
      'norm REAL NOT NULL DEFAULT 0, '
      'updated_at INTEGER NOT NULL, '
      'PRIMARY KEY (owner_type, owner_id, model))',

  // 召回记录
  'CREATE TABLE memory_recalls ('
      'id TEXT PRIMARY KEY, '
      'memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE, '
      'at INTEGER NOT NULL, '
      'conversation_id TEXT, '
      'message_id TEXT, '
      "reason TEXT NOT NULL DEFAULT 'retrieval', "
      'score REAL NOT NULL DEFAULT 0, '
      'used_in_prompt INTEGER NOT NULL DEFAULT 1)',
  'CREATE INDEX ix_memory_recalls_mem ON memory_recalls(memory_id, at)',

  // L2 情景
  'CREATE TABLE episodes ('
      'id TEXT PRIMARY KEY, '
      'scope TEXT NOT NULL, '
      'title TEXT NOT NULL, '
      "summary TEXT NOT NULL DEFAULT '', "
      'started_at INTEGER NOT NULL, '
      'ended_at INTEGER, '
      "time_precision TEXT NOT NULL DEFAULT 'day', "
      "participants_json TEXT NOT NULL DEFAULT '[]', "
      "emotion_json TEXT NOT NULL DEFAULT '{}', "
      'importance REAL NOT NULL DEFAULT 0.5, '
      'confidence REAL NOT NULL DEFAULT 0.5, '
      "source_kind TEXT NOT NULL DEFAULT 'real_interaction', "
      "status TEXT NOT NULL DEFAULT 'active', "
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL)',
  'CREATE INDEX ix_episodes_scope_time ON episodes(scope, started_at)',
  'CREATE TABLE episode_memories ('
      'episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE, '
      'memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE, '
      "role TEXT NOT NULL DEFAULT 'detail', "
      'PRIMARY KEY (episode_id, memory_id))',

  // L3 语义：实体与事实
  'CREATE TABLE entities ('
      'id TEXT PRIMARY KEY, '
      'kind TEXT NOT NULL, '
      'name TEXT NOT NULL, '
      'normalized_name TEXT NOT NULL, '
      "aliases_json TEXT NOT NULL DEFAULT '[]', "
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL)',
  'CREATE UNIQUE INDEX ux_entities ON entities(kind, normalized_name)',
  'CREATE TABLE entity_facts ('
      'id TEXT PRIMARY KEY, '
      'entity_id TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE, '
      'attribute TEXT NOT NULL, '
      'value TEXT NOT NULL, '
      'valid_from INTEGER, '
      'valid_to INTEGER, '
      'confidence REAL NOT NULL DEFAULT 0.6, '
      "epistemic_status TEXT NOT NULL DEFAULT 'observed', "
      "source_kind TEXT NOT NULL DEFAULT 'real_interaction', "
      'memory_id TEXT REFERENCES memories(id) ON DELETE SET NULL, '
      "status TEXT NOT NULL DEFAULT 'active', "
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL)',
  'CREATE INDEX ix_entity_facts_entity ON entity_facts(entity_id, attribute, status)',

  // L4 程序
  'CREATE TABLE procedural_memories ('
      'id TEXT PRIMARY KEY, '
      "scope TEXT NOT NULL DEFAULT 'shared', "
      'category TEXT NOT NULL, '
      'rule TEXT NOT NULL, '
      "trigger_condition TEXT NOT NULL DEFAULT '', "
      "examples_json TEXT NOT NULL DEFAULT '[]', "
      'confidence REAL NOT NULL DEFAULT 0.6, '
      'weight REAL NOT NULL DEFAULT 1.0, '
      "source_kind TEXT NOT NULL DEFAULT 'model_reflection', "
      'version INTEGER NOT NULL DEFAULT 1, '
      "status TEXT NOT NULL DEFAULT 'active', "
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL)',
  'CREATE INDEX ix_procedural_scope_cat ON procedural_memories(scope, category, status)',

  // L5 反思
  'CREATE TABLE reflections ('
      'id TEXT PRIMARY KEY, '
      "scope TEXT NOT NULL DEFAULT 'self', "
      'kind TEXT NOT NULL, '
      "subject TEXT NOT NULL DEFAULT '', "
      'content TEXT NOT NULL, '
      "conclusion TEXT NOT NULL DEFAULT '', "
      "input_refs_json TEXT NOT NULL DEFAULT '[]', "
      'confidence REAL NOT NULL DEFAULT 0.5, '
      "epistemic_status TEXT NOT NULL DEFAULT 'inferred', "
      "source_kind TEXT NOT NULL DEFAULT 'model_reflection', "
      "status TEXT NOT NULL DEFAULT 'active', "
      'superseded_by TEXT REFERENCES reflections(id), '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL)',
  'CREATE INDEX ix_reflections_scope_time ON reflections(scope, created_at)',

  // L6 时序知识图谱
  'CREATE TABLE kg_nodes ('
      'id TEXT PRIMARY KEY, '
      'kind TEXT NOT NULL, '
      'label TEXT NOT NULL, '
      'ref_type TEXT, '
      'ref_id TEXT, '
      "props_json TEXT NOT NULL DEFAULT '{}', "
      'created_at INTEGER NOT NULL)',
  'CREATE INDEX ix_kg_nodes_kind ON kg_nodes(kind, label)',
  'CREATE UNIQUE INDEX ux_kg_nodes_ref ON kg_nodes(ref_type, ref_id) WHERE ref_id IS NOT NULL',
  'CREATE TABLE kg_edges ('
      'id TEXT PRIMARY KEY, '
      'from_node_id TEXT NOT NULL REFERENCES kg_nodes(id) ON DELETE CASCADE, '
      'to_node_id TEXT NOT NULL REFERENCES kg_nodes(id) ON DELETE CASCADE, '
      'relation TEXT NOT NULL, '
      'valid_from INTEGER, '
      'valid_to INTEGER, '
      'confidence REAL NOT NULL DEFAULT 0.6, '
      "source_kind TEXT NOT NULL DEFAULT 'real_interaction', "
      'source_ref TEXT, '
      "props_json TEXT NOT NULL DEFAULT '{}', "
      'created_at INTEGER NOT NULL, '
      'CHECK (from_node_id <> to_node_id))',
  'CREATE INDEX ix_kg_edges_from ON kg_edges(from_node_id, relation)',
  'CREATE INDEX ix_kg_edges_to ON kg_edges(to_node_id, relation)',
  'CREATE INDEX ix_kg_edges_time ON kg_edges(valid_from, valid_to)',

  // 变化检测 / 未完成话题 / 工作记忆 / 任务队列
  'CREATE TABLE change_events ('
      'id TEXT PRIMARY KEY, '
      'scope TEXT NOT NULL, '
      'subject_type TEXT NOT NULL, '
      'subject_ref TEXT NOT NULL, '
      'dimension TEXT NOT NULL, '
      "from_value TEXT NOT NULL DEFAULT '', "
      "to_value TEXT NOT NULL DEFAULT '', "
      'detected_at INTEGER NOT NULL, '
      'confidence REAL NOT NULL DEFAULT 0.5, '
      "evidence_json TEXT NOT NULL DEFAULT '[]', "
      "status TEXT NOT NULL DEFAULT 'open')",
  'CREATE INDEX ix_change_events_time ON change_events(scope, detected_at)',
  'CREATE TABLE open_topics ('
      'id TEXT PRIMARY KEY, '
      "scope TEXT NOT NULL DEFAULT 'shared', "
      'title TEXT NOT NULL, '
      "summary TEXT NOT NULL DEFAULT '', "
      "status TEXT NOT NULL DEFAULT 'open', "
      'priority INTEGER NOT NULL DEFAULT 2, '
      'opened_at INTEGER NOT NULL, '
      'due_at INTEGER, '
      'last_touched_at INTEGER NOT NULL, '
      'closed_reason TEXT, '
      "evidence_json TEXT NOT NULL DEFAULT '[]')",
  'CREATE INDEX ix_open_topics_status ON open_topics(status, priority, due_at)',
  'CREATE TABLE working_memory_snapshots ('
      'id TEXT PRIMARY KEY, '
      'conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, '
      'built_at INTEGER NOT NULL, '
      'expires_at INTEGER NOT NULL, '
      'token_estimate INTEGER NOT NULL DEFAULT 0, '
      'message_count INTEGER NOT NULL DEFAULT 0, '
      'payload_json TEXT NOT NULL)',
  'CREATE INDEX ix_wm_conv ON working_memory_snapshots(conversation_id, built_at)',
  'CREATE TABLE memory_jobs ('
      'id TEXT PRIMARY KEY, '
      'kind TEXT NOT NULL, '
      'target_type TEXT, '
      'target_id TEXT, '
      'scope TEXT, '
      "payload_json TEXT NOT NULL DEFAULT '{}', "
      "status TEXT NOT NULL DEFAULT 'pending', "
      'priority INTEGER NOT NULL DEFAULT 5, '
      'attempts INTEGER NOT NULL DEFAULT 0, '
      'max_attempts INTEGER NOT NULL DEFAULT 3, '
      'scheduled_at INTEGER NOT NULL, '
      'started_at INTEGER, '
      'finished_at INTEGER, '
      'error TEXT, '
      'idempotency_key TEXT NOT NULL, '
      'created_at INTEGER NOT NULL)',
  'CREATE UNIQUE INDEX ux_memory_jobs_idem ON memory_jobs(idempotency_key)',
  'CREATE INDEX ix_memory_jobs_run ON memory_jobs(status, scheduled_at, priority)',

  // 分类历史
  'CREATE TABLE memory_classification_history ('
      'id TEXT PRIMARY KEY, '
      'memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE, '
      'from_scope TEXT, '
      'to_scope TEXT NOT NULL, '
      'from_status TEXT, '
      'to_status TEXT NOT NULL, '
      "reason TEXT NOT NULL DEFAULT '', "
      "evidence_json TEXT NOT NULL DEFAULT '[]', "
      'decided_by TEXT NOT NULL, '
      'import_batch_id TEXT, '
      'created_at INTEGER NOT NULL, '
      'reverted_at INTEGER, '
      'reverted_by TEXT)',
  'CREATE INDEX ix_class_history_memory ON memory_classification_history(memory_id, created_at)',
  'CREATE INDEX ix_class_history_batch ON memory_classification_history(import_batch_id, created_at)',

  // FTS5 虚表：不挂 external content，bigram 由应用层生成
  'CREATE VIRTUAL TABLE memory_fts USING fts5('
      'memory_id UNINDEXED, '
      'scope UNINDEXED, '
      'text_bigram, '
      "tokenize = 'unicode61')",

  // ── 备份与导入（v3，对齐原版 v7_meta_backup / v9_astrbot）────────────────

  // 备份清单：一份备份一行，校验和与加密标记必须落库
  'CREATE TABLE backup_manifests ('
      'id TEXT PRIMARY KEY, '
      "kind TEXT NOT NULL DEFAULT 'manual', "
      "scope TEXT NOT NULL DEFAULT 'full', "
      "status TEXT NOT NULL DEFAULT 'pending', "
      'schema_version TEXT NOT NULL, '
      "app_version TEXT NOT NULL DEFAULT '', "
      'file_name TEXT NOT NULL, '
      'rel_path TEXT NOT NULL, '
      'byte_size INTEGER NOT NULL DEFAULT 0, '
      'sha256 TEXT, '
      'is_encrypted INTEGER NOT NULL DEFAULT 1, '
      'encryption_hint TEXT, '
      "item_counts_json TEXT NOT NULL DEFAULT '{}', "
      'note TEXT, '
      'created_at INTEGER NOT NULL, '
      'finished_at INTEGER, '
      'verified_at INTEGER, '
      'retention_until INTEGER)',
  'CREATE INDEX ix_backup_manifests_time ON backup_manifests(created_at)',
  'CREATE INDEX ix_backup_manifests_status ON backup_manifests(status, created_at)',

  // 恢复日志：必须能表达"失败不破坏现库"
  'CREATE TABLE restore_logs ('
      'id TEXT PRIMARY KEY, '
      'backup_id TEXT REFERENCES backup_manifests(id) ON DELETE SET NULL, '
      "mode TEXT NOT NULL DEFAULT 'new_copy', "
      "status TEXT NOT NULL DEFAULT 'pending', "
      "preview_json TEXT NOT NULL DEFAULT '{}', "
      'is_compatible INTEGER NOT NULL DEFAULT 0, '
      'is_space_ok INTEGER NOT NULL DEFAULT 0, '
      'safety_backup_id TEXT REFERENCES backup_manifests(id) ON DELETE SET NULL, '
      "restored_counts_json TEXT NOT NULL DEFAULT '{}', "
      'started_at INTEGER NOT NULL, '
      'finished_at INTEGER, '
      'error TEXT)',
  'CREATE INDEX ix_restore_logs_backup ON restore_logs(backup_id, started_at)',
  'CREATE INDEX ix_restore_logs_status ON restore_logs(status, started_at)',

  // AstrBot 迁移批次：一次导入一行，重试与回滚都以批次为单位
  'CREATE TABLE astrbot_migration_batches ('
      'id TEXT PRIMARY KEY, '
      "source_kind TEXT NOT NULL DEFAULT 'astrbot', "
      "source_ref TEXT NOT NULL DEFAULT '', "
      'source_hash TEXT, '
      'is_dry_run INTEGER NOT NULL DEFAULT 1, '
      "status TEXT NOT NULL DEFAULT 'pending', "
      "options_json TEXT NOT NULL DEFAULT '{}', "
      "counts_json TEXT NOT NULL DEFAULT '{}', "
      "checkpoint_json TEXT NOT NULL DEFAULT '{}', "
      'started_at INTEGER NOT NULL, '
      'finished_at INTEGER, '
      'error TEXT)',
  'CREATE INDEX ix_astrbot_batches_time ON astrbot_migration_batches(started_at)',
  'CREATE INDEX ix_astrbot_batches_status ON astrbot_migration_batches(status, started_at)',

  // AstrBot 原始 ID 映射：同一批次内同一实体的原始 ID 只能映射一次
  'CREATE TABLE astrbot_id_map ('
      'id TEXT PRIMARY KEY, '
      'batch_id TEXT NOT NULL REFERENCES astrbot_migration_batches(id) ON DELETE CASCADE, '
      'entity_kind TEXT NOT NULL, '
      'source_id TEXT NOT NULL, '
      'target_id TEXT NOT NULL, '
      'source_hash TEXT, '
      'created_at INTEGER NOT NULL)',
  'CREATE UNIQUE INDEX ux_astrbot_id_map ON astrbot_id_map(batch_id, entity_kind, source_id)',

  // AstrBot 待处理区：未识别/冲突数据保留原始内容，等待人工决定
  'CREATE TABLE astrbot_import_pending ('
      'id TEXT PRIMARY KEY, '
      'batch_id TEXT NOT NULL REFERENCES astrbot_migration_batches(id) ON DELETE CASCADE, '
      'entity_kind TEXT NOT NULL, '
      'source_id TEXT, '
      'reason_code TEXT NOT NULL, '
      'raw_json TEXT NOT NULL, '
      "status TEXT NOT NULL DEFAULT 'pending', "
      'resolved_target_id TEXT, '
      'created_at INTEGER NOT NULL, '
      'resolved_at INTEGER)',
  'CREATE INDEX ix_astrbot_pending_batch ON astrbot_import_pending(batch_id, status)',
  'CREATE INDEX ix_astrbot_pending_kind ON astrbot_import_pending(entity_kind, status)',

  // 视图：三套记忆 + 统计
  "CREATE VIEW v_memory_user AS SELECT * FROM memories WHERE scope = 'user' AND status <> 'deleted'",
  "CREATE VIEW v_memory_shared AS SELECT * FROM memories WHERE scope = 'shared' AND status <> 'deleted'",
  "CREATE VIEW v_memory_self AS SELECT * FROM memories WHERE scope = 'self' AND status <> 'deleted'",
  'CREATE VIEW v_memory_stats AS '
      'SELECT m.scope, m.layer, COUNT(*) AS total, '
      "SUM(CASE WHEN m.status = 'active' THEN 1 ELSE 0 END) AS active_count, "
      "SUM(CASE WHEN m.status = 'pending_confirm' THEN 1 ELSE 0 END) AS pending_count, "
      "SUM(CASE WHEN m.status = 'disputed' THEN 1 ELSE 0 END) AS disputed_count, "
      "SUM(CASE WHEN m.heat = 'hot' THEN 1 ELSE 0 END) AS hot_count, "
      'MAX(m.last_recalled_at) AS last_recalled_at '
      'FROM memories m WHERE m.status <> \'deleted\' GROUP BY m.scope, m.layer',
];

/// 迁移升级路径：`oldVersion → newVersion` 时追加执行的语句。
/// 首次安装（version 0）由 sqflite 的 onCreate 走 [kSchemaStatements] 全量建表。
const Map<int, List<String>> kUpgradeStatements = <int, List<String>>{
  // v3：备份清单 / 恢复日志 / AstrBot 迁移三表（全新表，无历史数据改动）
  3: <String>[
    'CREATE TABLE IF NOT EXISTS backup_manifests ('
        'id TEXT PRIMARY KEY, '
        "kind TEXT NOT NULL DEFAULT 'manual', "
        "scope TEXT NOT NULL DEFAULT 'full', "
        "status TEXT NOT NULL DEFAULT 'pending', "
        'schema_version TEXT NOT NULL, '
        "app_version TEXT NOT NULL DEFAULT '', "
        'file_name TEXT NOT NULL, '
        'rel_path TEXT NOT NULL, '
        'byte_size INTEGER NOT NULL DEFAULT 0, '
        'sha256 TEXT, '
        'is_encrypted INTEGER NOT NULL DEFAULT 1, '
        'encryption_hint TEXT, '
        "item_counts_json TEXT NOT NULL DEFAULT '{}', "
        'note TEXT, '
        'created_at INTEGER NOT NULL, '
        'finished_at INTEGER, '
        'verified_at INTEGER, '
        'retention_until INTEGER)',
    'CREATE INDEX IF NOT EXISTS ix_backup_manifests_time ON backup_manifests(created_at)',
    'CREATE INDEX IF NOT EXISTS ix_backup_manifests_status ON backup_manifests(status, created_at)',
    'CREATE TABLE IF NOT EXISTS restore_logs ('
        'id TEXT PRIMARY KEY, '
        'backup_id TEXT REFERENCES backup_manifests(id) ON DELETE SET NULL, '
        "mode TEXT NOT NULL DEFAULT 'new_copy', "
        "status TEXT NOT NULL DEFAULT 'pending', "
        "preview_json TEXT NOT NULL DEFAULT '{}', "
        'is_compatible INTEGER NOT NULL DEFAULT 0, '
        'is_space_ok INTEGER NOT NULL DEFAULT 0, '
        'safety_backup_id TEXT REFERENCES backup_manifests(id) ON DELETE SET NULL, '
        "restored_counts_json TEXT NOT NULL DEFAULT '{}', "
        'started_at INTEGER NOT NULL, '
        'finished_at INTEGER, '
        'error TEXT)',
    'CREATE INDEX IF NOT EXISTS ix_restore_logs_backup ON restore_logs(backup_id, started_at)',
    'CREATE INDEX IF NOT EXISTS ix_restore_logs_status ON restore_logs(status, started_at)',
    'CREATE TABLE IF NOT EXISTS astrbot_migration_batches ('
        'id TEXT PRIMARY KEY, '
        "source_kind TEXT NOT NULL DEFAULT 'astrbot', "
        "source_ref TEXT NOT NULL DEFAULT '', "
        'source_hash TEXT, '
        'is_dry_run INTEGER NOT NULL DEFAULT 1, '
        "status TEXT NOT NULL DEFAULT 'pending', "
        "options_json TEXT NOT NULL DEFAULT '{}', "
        "counts_json TEXT NOT NULL DEFAULT '{}', "
        "checkpoint_json TEXT NOT NULL DEFAULT '{}', "
        'started_at INTEGER NOT NULL, '
        'finished_at INTEGER, '
        'error TEXT)',
    'CREATE INDEX IF NOT EXISTS ix_astrbot_batches_time ON astrbot_migration_batches(started_at)',
    'CREATE INDEX IF NOT EXISTS ix_astrbot_batches_status ON astrbot_migration_batches(status, started_at)',
    'CREATE TABLE IF NOT EXISTS astrbot_id_map ('
        'id TEXT PRIMARY KEY, '
        'batch_id TEXT NOT NULL REFERENCES astrbot_migration_batches(id) ON DELETE CASCADE, '
        'entity_kind TEXT NOT NULL, '
        'source_id TEXT NOT NULL, '
        'target_id TEXT NOT NULL, '
        'source_hash TEXT, '
        'created_at INTEGER NOT NULL)',
    'CREATE UNIQUE INDEX IF NOT EXISTS ux_astrbot_id_map ON astrbot_id_map(batch_id, entity_kind, source_id)',
    'CREATE TABLE IF NOT EXISTS astrbot_import_pending ('
        'id TEXT PRIMARY KEY, '
        'batch_id TEXT NOT NULL REFERENCES astrbot_migration_batches(id) ON DELETE CASCADE, '
        'entity_kind TEXT NOT NULL, '
        'source_id TEXT, '
        'reason_code TEXT NOT NULL, '
        'raw_json TEXT NOT NULL, '
        "status TEXT NOT NULL DEFAULT 'pending', "
        'resolved_target_id TEXT, '
        'created_at INTEGER NOT NULL, '
        'resolved_at INTEGER)',
    'CREATE INDEX IF NOT EXISTS ix_astrbot_pending_batch ON astrbot_import_pending(batch_id, status)',
    'CREATE INDEX IF NOT EXISTS ix_astrbot_pending_kind ON astrbot_import_pending(entity_kind, status)',
  ],
};
