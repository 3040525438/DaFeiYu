/// AstrBot 全量导入模型（对齐 SwiftUI 版 DFCore `AstrBotImport.swift`，W9 / 决策 38–40）。
///
/// 硬规则：
/// 1. **只读源数据**：先把源文件复制到暂存目录再打开，原件只做 SHA256 前后比对；
/// 2. **只增不覆盖**：不修改任何既有会话/消息/记忆/人格，冲突一律进待处理区；
/// 3. **每行有归属**：每个源行必须落入"新增 / 重复 / 待处理"之一，覆盖校验失败即整批回滚；
/// 4. **可回滚**：`astrbot_id_map` 记录本批次造出的每一个目标 ID，回滚只删这些；
/// 5. **可追溯**：批次、计数、报告、待处理原因、原始 JSON 全部落库。
library;

import 'dart:convert';

/// 数据源路径。所有源文件一律**只读**：导入器不写、不改、不删。
class AstrBotSourcePaths {
  const AstrBotSourcePaths({
    this.chatMemoryDatabase,
    this.longTermMemoryDatabase,
    this.personaDatabase,
    this.diaryDirectory,
    this.lettersDirectory,
    this.bookNotesDirectory,
    this.companionLedgerJson,
    this.configJson,
  });

  /// 聊天记录库：`data/plugin_data/chat_memory/chat_memory.db`
  final String? chatMemoryDatabase;

  /// 长期记忆库：`diary/memory.db`
  final String? longTermMemoryDatabase;

  /// 人格库：`data/data_v4.db`
  final String? personaDatabase;

  /// 日记目录：`diary/`（只取 `yyyy-MM-dd.md`，`txt/` 视为镜像）
  final String? diaryDirectory;

  /// 信件目录：`letters/`
  final String? lettersDirectory;

  /// 读书笔记目录：`books/notes/`
  final String? bookNotesDirectory;

  /// 关系账本：`data/plugin_data/astrbot_plugin_private_companion/companions.json`
  final String? companionLedgerJson;

  /// AstrBot 主配置：`data/cmd_config.json`（只做脱敏留档，不自动应用）
  final String? configJson;

  /// 至少提供一个数据源才允许启动导入
  bool get hasAnySource =>
      chatMemoryDatabase != null ||
      longTermMemoryDatabase != null ||
      personaDatabase != null ||
      diaryDirectory != null ||
      lettersDirectory != null ||
      bookNotesDirectory != null ||
      companionLedgerJson != null ||
      configJson != null;
}

/// 导入选项
class AstrBotImportOptions {
  const AstrBotImportOptions({
    this.isDryRun = true,
    this.conversationTitlePrefix = 'AstrBot 迁移',
    this.personaName = '大肥鱼',
    this.importsDocuments = true,
    this.importsRelationshipLedger = true,
    this.stagingDirectory,
    this.replacesCorePersona = false,
    this.replacesPreviousImports = false,
    this.prunesNonImportedConversations = false,
  });

  /// 预演：完整跑一遍映射与校验，然后整体回滚，只留批次报告
  final bool isDryRun;

  /// 会话标题前缀
  final String conversationTitlePrefix;

  /// 迁移后核心人格的显示名
  final String personaName;

  /// 是否导入信件与读书笔记
  final bool importsDocuments;

  /// 是否把关系账本收进记忆与待处理区
  final bool importsRelationshipLedger;

  /// 源文件暂存目录：设置后先把源文件复制到该目录再打开，原件完全不触碰
  final String? stagingDirectory;

  /// 是否用源人格替换当前核心人格（原位替换，写新版本，可回退）
  final bool replacesCorePersona;

  /// 是否先清理上一次导入写入的数据（覆盖式导入，避免重复累积）
  final bool replacesPreviousImports;

  /// 导入后是否归档非导入会话（聊天页只看到导入的）
  final bool prunesNonImportedConversations;
}

/// 批次状态（与 `astrbot_migration_batches.status` 一致）
enum AstrBotImportStatus {
  running,
  succeeded,
  dryRunSucceeded('dry_run_succeeded'),
  failed,
  rolledBack('rolled_back');

  const AstrBotImportStatus([this.wire]);
  final String? wire;

  String get value => wire ?? name;

  static AstrBotImportStatus fromWire(String? value) {
    return AstrBotImportStatus.values.firstWhere(
      (AstrBotImportStatus s) => s.value == value,
      orElse: () => AstrBotImportStatus.failed,
    );
  }
}

/// 导入涉及的实体类型（与 `astrbot_id_map.entity_kind` 口径一致）
enum AstrBotEntityKind {
  conversation,
  message,
  memory,
  diary,
  persona,
  personaItem('persona_item'),
  document,
  relationshipMilestone('relationship_milestone'),
  relationshipStageProposal('relationship_stage_proposal');

  const AstrBotEntityKind([this.wire]);
  final String? wire;

  String get value => wire ?? name;
}

/// 待处理原因码。新增值只能追加，不改已有字符串。
enum AstrBotPendingReason {
  unknownRole('unknown_role'),
  systemEvent('system_event'),
  mediaMissing('media_missing'),
  toolRecord('tool_record'),
  mediaArchive('media_archive'),
  invalidTimestamp('invalid_timestamp'),
  emptyContent('empty_content'),
  invalidDay('invalid_day'),
  diaryDateConflict('diary_date_conflict'),
  unrecognizedDiaryFile('unrecognized_diary_file'),
  personaConflict('persona_conflict'),
  relationshipLedger('relationship_ledger'),
  replyTargetMissing('reply_target_missing'),
  unsupportedContentKind('unsupported_content_kind'),
  unsupportedConfig('unsupported_config'),
  /// Flutter 版尚无对应表（日记/关系里程碑）时整行进待处理区，不丢数据
  featureNotAvailable('feature_not_available');

  const AstrBotPendingReason(this.wire);
  final String wire;

  String get value => wire;
}

/// 导入计数。覆盖式校验的唯一依据：每个源行必须落入"导入 / 重复 / 待处理"之一。
class AstrBotImportCounts {
  AstrBotImportCounts();

  int sourceChatRecords = 0;
  int sourceToolRecords = 0;
  int sourceMediaArchives = 0;

  int messagesNew = 0;
  int messagesDuplicate = 0;
  int messagesPending = 0;

  int sourceMemories = 0;
  int memoriesNew = 0;
  int memoriesDuplicate = 0;
  int memoriesPending = 0;

  int sourceDiaryFiles = 0;
  int diariesNew = 0;
  int diaryDuplicates = 0;
  int diaryMirrors = 0;
  int diaryPending = 0;

  int sourcePersonaRows = 0;
  int personaRowsImported = 0;
  int personaPending = 0;
  int personaItemsNew = 0;

  int sourceDocuments = 0;
  int documentsNew = 0;
  int documentsDuplicate = 0;
  int documentsPending = 0;

  int sourceLedgerUsers = 0;
  int ledgerPending = 0;
  /// 关系账本中成功迁移的用户数
  int relationshipUsersImported = 0;
  int sourceCompanionMemories = 0;
  int companionMemoriesNew = 0;
  int companionMemoriesDuplicate = 0;
  int companionMemoriesPending = 0;
  int sourceRelationshipMilestones = 0;
  int relationshipMilestonesNew = 0;
  int relationshipMilestonesDuplicate = 0;
  int relationshipMilestonesPending = 0;
  int relationshipProposalsNew = 0;
  int sourceConfigFiles = 0;
  int configPending = 0;

  int pendingMediaMissing = 0;
  int pendingReplyTargetMissing = 0;
  int pendingToolRecords = 0;
  int pendingMediaArchives = 0;

  int pendingTotal = 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'source_chat_records': sourceChatRecords,
    'source_tool_records': sourceToolRecords,
    'source_media_archives': sourceMediaArchives,
    'messages_new': messagesNew,
    'messages_duplicate': messagesDuplicate,
    'messages_pending': messagesPending,
    'source_memories': sourceMemories,
    'memories_new': memoriesNew,
    'memories_duplicate': memoriesDuplicate,
    'memories_pending': memoriesPending,
    'source_diary_files': sourceDiaryFiles,
    'diaries_new': diariesNew,
    'diary_duplicates': diaryDuplicates,
    'diary_mirrors': diaryMirrors,
    'diary_pending': diaryPending,
    'source_persona_rows': sourcePersonaRows,
    'persona_rows_imported': personaRowsImported,
    'persona_pending': personaPending,
    'persona_items_new': personaItemsNew,
    'source_documents': sourceDocuments,
    'documents_new': documentsNew,
    'documents_duplicate': documentsDuplicate,
    'documents_pending': documentsPending,
    'source_ledger_users': sourceLedgerUsers,
    'ledger_pending': ledgerPending,
    'relationship_users_imported': relationshipUsersImported,
    'source_companion_memories': sourceCompanionMemories,
    'companion_memories_new': companionMemoriesNew,
    'companion_memories_duplicate': companionMemoriesDuplicate,
    'companion_memories_pending': companionMemoriesPending,
    'source_relationship_milestones': sourceRelationshipMilestones,
    'relationship_milestones_new': relationshipMilestonesNew,
    'relationship_milestones_duplicate': relationshipMilestonesDuplicate,
    'relationship_milestones_pending': relationshipMilestonesPending,
    'relationship_proposals_new': relationshipProposalsNew,
    'source_config_files': sourceConfigFiles,
    'config_pending': configPending,
    'pending_media_missing': pendingMediaMissing,
    'pending_reply_target_missing': pendingReplyTargetMissing,
    'pending_tool_records': pendingToolRecords,
    'pending_media_archives': pendingMediaArchives,
    'pending_total': pendingTotal,
  };

  static AstrBotImportCounts fromJson(String json) {
    final counts = AstrBotImportCounts();
    try {
      final Map<String, Object?> root = jsonDecode(json) as Map<String, Object?>;
      int read(String key, int fallback) => (root[key] as int?) ?? fallback;
      counts.sourceChatRecords = read('source_chat_records', 0);
      counts.sourceToolRecords = read('source_tool_records', 0);
      counts.sourceMediaArchives = read('source_media_archives', 0);
      counts.messagesNew = read('messages_new', 0);
      counts.messagesDuplicate = read('messages_duplicate', 0);
      counts.messagesPending = read('messages_pending', 0);
      counts.sourceMemories = read('source_memories', 0);
      counts.memoriesNew = read('memories_new', 0);
      counts.memoriesDuplicate = read('memories_duplicate', 0);
      counts.memoriesPending = read('memories_pending', 0);
      counts.sourceDiaryFiles = read('source_diary_files', 0);
      counts.diariesNew = read('diaries_new', 0);
      counts.diaryDuplicates = read('diary_duplicates', 0);
      counts.diaryMirrors = read('diary_mirrors', 0);
      counts.diaryPending = read('diary_pending', 0);
      counts.sourcePersonaRows = read('source_persona_rows', 0);
      counts.personaRowsImported = read('persona_rows_imported', 0);
      counts.personaPending = read('persona_pending', 0);
      counts.personaItemsNew = read('persona_items_new', 0);
      counts.sourceDocuments = read('source_documents', 0);
      counts.documentsNew = read('documents_new', 0);
      counts.documentsDuplicate = read('documents_duplicate', 0);
      counts.documentsPending = read('documents_pending', 0);
      counts.sourceLedgerUsers = read('source_ledger_users', 0);
      counts.ledgerPending = read('ledger_pending', 0);
      counts.relationshipUsersImported = read('relationship_users_imported', 0);
      counts.sourceCompanionMemories = read('source_companion_memories', 0);
      counts.companionMemoriesNew = read('companion_memories_new', 0);
      counts.companionMemoriesDuplicate = read('companion_memories_duplicate', 0);
      counts.companionMemoriesPending = read('companion_memories_pending', 0);
      counts.sourceRelationshipMilestones = read('source_relationship_milestones', 0);
      counts.relationshipMilestonesNew = read('relationship_milestones_new', 0);
      counts.relationshipMilestonesDuplicate = read('relationship_milestones_duplicate', 0);
      counts.relationshipMilestonesPending = read('relationship_milestones_pending', 0);
      counts.relationshipProposalsNew = read('relationship_proposals_new', 0);
      counts.sourceConfigFiles = read('source_config_files', 0);
      counts.configPending = read('config_pending', 0);
      counts.pendingMediaMissing = read('pending_media_missing', 0);
      counts.pendingReplyTargetMissing = read('pending_reply_target_missing', 0);
      counts.pendingToolRecords = read('pending_tool_records', 0);
      counts.pendingMediaArchives = read('pending_media_archives', 0);
      counts.pendingTotal = read('pending_total', 0);
    } catch (_) {
      // 解析失败返回全零计数，不阻塞批次展示
    }
    return counts;
  }

  /// 源行覆盖校验：不一致说明有行被静默丢弃
  List<String> get coverageProblems {
    final problems = <String>[];
    void check(String label, int source, int expected, String breakdown) {
      if (source != expected) {
        problems.add('$label：源 $source ≠ $breakdown');
      }
    }

    check(
      '聊天',
      sourceChatRecords,
      messagesNew + messagesDuplicate + messagesPending,
      '新增 $messagesNew + 重复 $messagesDuplicate + 待处理 $messagesPending',
    );
    check(
      '记忆',
      sourceMemories,
      memoriesNew + memoriesDuplicate + memoriesPending,
      '新增 $memoriesNew + 重复 $memoriesDuplicate + 待处理 $memoriesPending',
    );
    check(
      '日记',
      sourceDiaryFiles,
      diariesNew + diaryDuplicates + diaryMirrors + diaryPending,
      '新增 $diariesNew + 重复 $diaryDuplicates + 镜像 $diaryMirrors + 待处理 $diaryPending',
    );
    check(
      '人格',
      sourcePersonaRows,
      personaRowsImported + personaPending,
      '导入 $personaRowsImported + 待处理 $personaPending',
    );
    check(
      '文档',
      sourceDocuments,
      documentsNew + documentsDuplicate + documentsPending,
      '新增 $documentsNew + 重复 $documentsDuplicate + 待处理 $documentsPending',
    );
    check(
      '关系账本',
      sourceLedgerUsers,
      relationshipUsersImported + ledgerPending,
      '已迁移 $relationshipUsersImported + 待处理 $ledgerPending',
    );
    check(
      '关系档案',
      sourceCompanionMemories,
      companionMemoriesNew + companionMemoriesDuplicate + companionMemoriesPending,
      '新增 $companionMemoriesNew + 重复 $companionMemoriesDuplicate + 待处理 $companionMemoriesPending',
    );
    check(
      '关系里程碑',
      sourceRelationshipMilestones,
      relationshipMilestonesNew + relationshipMilestonesDuplicate + relationshipMilestonesPending,
      '新增 $relationshipMilestonesNew + 重复 $relationshipMilestonesDuplicate + 待处理 $relationshipMilestonesPending',
    );
    check('配置文件', sourceConfigFiles, configPending, '留档 $configPending');
    check('工具记录', sourceToolRecords, pendingToolRecords, '待处理 $pendingToolRecords');
    check('媒体归档', sourceMediaArchives, pendingMediaArchives, '待处理 $pendingMediaArchives');
    return problems;
  }
}

/// 一次导入的对外报告
class AstrBotImportReport {
  AstrBotImportReport({
    required this.batchId,
    required this.status,
    required this.isDryRun,
    required this.sourceHash,
    required this.startedAt,
    this.finishedAt,
    required this.counts,
    required this.pendingByReason,
  });

  final String batchId;
  final AstrBotImportStatus status;
  final bool isDryRun;
  final String sourceHash;
  final int startedAt;
  final int? finishedAt;
  final AstrBotImportCounts counts;
  final Map<String, int> pendingByReason;
}

/// 批次摘要（用于界面列表）
class AstrBotBatchSummary {
  AstrBotBatchSummary({
    required this.id,
    required this.isDryRun,
    required this.status,
    required this.sourceRef,
    required this.sourceHash,
    required this.startedAt,
    this.finishedAt,
    this.error,
    required this.counts,
  });

  final String id;
  final bool isDryRun;
  final String status;
  final String sourceRef;
  final String? sourceHash;
  final int startedAt;
  final int? finishedAt;
  final String? error;
  final AstrBotImportCounts counts;
}

/// 待处理区条目：未识别/冲突数据保留原始内容，等待人工决定
class AstrBotPendingItem {
  AstrBotPendingItem({
    required this.id,
    required this.batchId,
    required this.entityKind,
    required this.sourceId,
    required this.reasonCode,
    required this.rawJson,
    required this.status,
    required this.resolvedTargetId,
    required this.createdAt,
    this.resolvedAt,
  });

  final String id;
  final String batchId;
  final String entityKind;
  final String? sourceId;
  final String reasonCode;
  final String rawJson;
  final String status;
  final String? resolvedTargetId;
  final int createdAt;
  final int? resolvedAt;
}

/// 回滚结果：只删本批次造出来的东西
class AstrBotRollbackReport {
  AstrBotRollbackReport({
    required this.batchId,
    required this.status,
    required this.deletedMessages,
    required this.deletedConversations,
    required this.deletedMemories,
    required this.deletedPersonaItems,
    required this.deletedPersonas,
    required this.deletedDocuments,
    required this.deletedPending,
    required this.deletedIdMaps,
  });

  final String batchId;
  final AstrBotImportStatus status;
  final int deletedMessages;
  final int deletedConversations;
  final int deletedMemories;
  final int deletedPersonaItems;
  final int deletedPersonas;
  final int deletedDocuments;
  final int deletedPending;
  final int deletedIdMaps;
}

/// AstrBot 导入错误
class AstrBotImportError implements Exception {
  AstrBotImportError(this.message);
  final String message;

  static AstrBotImportError get noSource =>
      AstrBotImportError('未提供任何 AstrBot 数据源');
  static AstrBotImportError sourceMissing(String path) =>
      AstrBotImportError('数据源不存在：$path');
  static AstrBotImportError sourceUnreadable(String path) =>
      AstrBotImportError('数据源无法读取：$path');
  static AstrBotImportError sourceChanged(String path) =>
      AstrBotImportError('导入期间源文件发生变化，已中止：$path');
  static AstrBotImportError invalidBatch(String id) =>
      AstrBotImportError('导入批次不存在：$id');
  static AstrBotImportError alreadyRolledBack(String id) =>
      AstrBotImportError('该批次已回滚：$id');
  static AstrBotImportError rollbackNotAllowed(String reason) =>
      AstrBotImportError('当前批次不允许回滚：$reason');
  static AstrBotImportError pendingNotFound(String id) =>
      AstrBotImportError('待处理条目不存在：$id');
  static AstrBotImportError coverageMismatch(List<String> problems) =>
      AstrBotImportError('导入覆盖校验失败：${problems.join('；')}');

  @override
  String toString() => message;
}

/// 预演回滚信号：只用于跳出事务，不对外暴露
class AstrBotDryRunSignal implements Exception {}
