/// AstrBot 全量导入器（对齐 SwiftUI 版 DFData `AstrBotImporter.swift`）。
///
/// Flutter 版（P0）范围与原版的差异：
/// - 支持聊天库 / 长期记忆库 / 人格库 / 信件与读书笔记（作为文档记忆）/ 关系账本 / 主配置留档；
/// - 日记目录与关系里程碑：Flutter 版尚无对应表，源行**整体进待处理区**
///   （reason=feature_not_available），覆盖校验仍成立，不丢数据；P1 建表后打开；
/// - persona_fingerprints / persona_imports / relationship_* 表不存在，对应写入跳过。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../data/db/app_database.dart';
import '../text/bigram.dart';
import 'astrbot_import.dart';

class AstrBotImporter {
  AstrBotImporter(this._db);

  final AppDatabase _db;
  final Uuid _uuid = const Uuid();

  // ── 预演 / 正式导入 ────────────────────────────────────────────────────────

  Future<AstrBotImportReport> run(
    AstrBotSourcePaths source,
    AstrBotImportOptions options,
  ) async {
    if (!source.hasAnySource) throw AstrBotImportError.noSource;

    final startedAt = DateTime.now().millisecondsSinceEpoch;

    _PreparedSources prepared;
    try {
      prepared = await _prepareSources(source);
    } catch (error) {
      // 源缺失/不可读也要留痕，避免"失败却没有记录"
      final message = error is AstrBotImportError ? error.message : error.toString();
      await _recordFailure(
        batchId: 'astrbot-$startedAt-preparefailed',
        isDryRun: options.isDryRun,
        sourceRef: '',
        sourceHash: '',
        startedAt: startedAt,
        counts: AstrBotImportCounts(),
        error: message,
      );
      rethrow;
    }

    try {
      final batchId = 'astrbot-$startedAt-${prepared.sourceHash.substring(0, 8)}';

      // 覆盖式导入：先清掉上一次导入写入的数据（只删导入批次带进来的），
      // 必须先回滚再读核心人格，否则会拿到已被删除的 persona id。
      if (options.replacesPreviousImports && !options.isDryRun) {
        final rows = await _db.db.query(
          'astrbot_migration_batches',
          columns: <String>['id'],
          where: 'status = ?',
          whereArgs: <Object?>[AstrBotImportStatus.succeeded.value],
          orderBy: 'started_at',
        );
        for (final Map<String, Object?> row in rows) {
          try {
            await rollback(row['id']! as String, atMillis: _now());
          } catch (_) {
            // 上批回滚失败不阻断本次导入
          }
        }
      }

      // 可选：导入后只保留导入的会话（归档而非物理删除，避免外键约束问题）
      if (options.prunesNonImportedConversations && !options.isDryRun) {
        final archiveAt = _now();
        await _db.db.execute(
          'UPDATE conversations '
          'SET archived_at = COALESCE(archived_at, ?), updated_at = ? '
          "WHERE COALESCE(kind, '') <> 'imported'",
          <Object?>[archiveAt, archiveAt],
        );
      }

      // 已有核心人格的 id 与当前提示词：识别"首启占位人格"并决定是否原位替换
      final corePersona = await _readCorePersona();
      final existingCorePersona = corePersona?.$1;
      final existingCorePrompt = corePersona?.$2;

      final plan = await _buildPlan(
        prepared,
        options,
        existingCorePersona: existingCorePersona,
        existingCorePrompt: existingCorePrompt,
      );

      final outcome = _ImportOutcome(plan.counts);
      Object? failure;

      try {
        await _db.db.transaction((DatabaseExecutor txn) async {
          await _insertBatch(
            txn,
            batchId: batchId,
            status: AstrBotImportStatus.running,
            isDryRun: options.isDryRun,
            sourceRef: prepared.sourceRef,
            sourceHash: prepared.sourceHash,
            startedAt: startedAt,
            counts: plan.counts,
            error: null,
          );

          final legacyBefore = await _legacyFingerprint(txn);
          await _apply(txn, plan, batchId, startedAt, outcome);
          await _verifyPostconditions(txn, plan, outcome, legacyBefore);

          if (options.isDryRun) {
            // 预演：主动抛错回滚整个事务，只保留内存里的计数
            throw AstrBotDryRunSignal();
          }

          await _updateBatchFinished(
            txn,
            batchId: batchId,
            status: AstrBotImportStatus.succeeded,
            finishedAt: _now(),
            counts: outcome.counts,
            error: null,
          );
        });
      } on AstrBotDryRunSignal {
        // 事务已整体回滚，单独写一条预演批次记录
        final finishedAt = _now();
        await _db.db.transaction((DatabaseExecutor txn) async {
          await _insertBatch(
            txn,
            batchId: batchId,
            status: AstrBotImportStatus.dryRunSucceeded,
            isDryRun: true,
            sourceRef: prepared.sourceRef,
            sourceHash: prepared.sourceHash,
            startedAt: startedAt,
            counts: outcome.counts,
            error: null,
          );
          await _updateBatchFinished(
            txn,
            batchId: batchId,
            status: AstrBotImportStatus.dryRunSucceeded,
            finishedAt: finishedAt,
            counts: outcome.counts,
            error: null,
          );
        });
      } catch (error) {
        failure = error;
      }

      // 原始数据保护：导入前后源文件指纹必须一致
      await prepared.verifyUnchanged();

      if (failure != null) {
        final message = failure is AstrBotImportError ? failure.message : failure.toString();
        await _recordFailure(
          batchId: batchId,
          isDryRun: options.isDryRun,
          sourceRef: prepared.sourceRef,
          sourceHash: prepared.sourceHash,
          startedAt: startedAt,
          counts: outcome.counts,
          error: message,
        );
        throw failure;
      }

      return AstrBotImportReport(
        batchId: batchId,
        status: options.isDryRun
            ? AstrBotImportStatus.dryRunSucceeded
            : AstrBotImportStatus.succeeded,
        isDryRun: options.isDryRun,
        sourceHash: prepared.sourceHash,
        startedAt: startedAt,
        finishedAt: _now(),
        counts: outcome.counts,
        pendingByReason: outcome.pendingByReason,
      );
    } finally {
      prepared.cleanUpStaging();
    }
  }

  // ── 回滚 ─────────────────────────────────────────────────────────────────

  Future<AstrBotRollbackReport> rollback(String batchId, {required int atMillis}) async {
    return _db.db.transaction((DatabaseExecutor txn) async {
      final statusRows = await txn.query(
        'astrbot_migration_batches',
        columns: <String>['status'],
        where: 'id = ?',
        whereArgs: <Object?>[batchId],
        limit: 1,
      );
      if (statusRows.isEmpty) throw AstrBotImportError.invalidBatch(batchId);
      final status = statusRows.first['status'] as String?;
      if (status == AstrBotImportStatus.rolledBack.value) {
        throw AstrBotImportError.alreadyRolledBack(batchId);
      }
      if (status == AstrBotImportStatus.running.value) {
        throw AstrBotImportError.rollbackNotAllowed('批次仍在执行中');
      }

      Future<List<String>> targetIds(String kind) async {
        final rows = await txn.query(
          'astrbot_id_map',
          columns: <String>['target_id'],
          where: 'batch_id = ? AND entity_kind = ?',
          whereArgs: <Object?>[batchId, kind],
        );
        return rows.map((Map<String, Object?> r) => r['target_id']! as String).toList();
      }

      final messageIds = await targetIds('message');
      final conversationIds = await targetIds('conversation');
      final memoryIds = <String>[...await targetIds('memory'), ...await targetIds('document')];
      final personaItemIds = await targetIds('persona_item');
      final personaIds = await targetIds('persona');

      Future<int> deleteBy(String table, String column, List<String> ids) async {
        var deleted = 0;
        for (final String id in ids) {
          deleted += await txn.delete(table, where: '$column = ?', whereArgs: <Object?>[id]);
        }
        return deleted;
      }

      // FTS 索引随行删除
      await deleteBy('memory_fts', 'memory_id', memoryIds);

      final deletedMessages = await deleteBy('messages', 'id', messageIds);
      final deletedConversations = await deleteBy('conversations', 'id', conversationIds);
      final deletedMemories = await deleteBy('memories', 'id', memoryIds);
      final deletedPersonaItems = await deleteBy('persona_items', 'id', personaItemIds);
      final deletedPersonas = await deleteBy('personas', 'id', personaIds);

      final deletedPending = await txn.delete(
        'astrbot_import_pending',
        where: 'batch_id = ?',
        whereArgs: <Object?>[batchId],
      );
      final deletedIdMaps = await txn.delete(
        'astrbot_id_map',
        where: 'batch_id = ?',
        whereArgs: <Object?>[batchId],
      );

      await txn.update(
        'astrbot_migration_batches',
        <String, Object?>{
          'status': AstrBotImportStatus.rolledBack.value,
          'finished_at': atMillis,
          'error': null,
        },
        where: 'id = ?',
        whereArgs: <Object?>[batchId],
      );

      return AstrBotRollbackReport(
        batchId: batchId,
        status: AstrBotImportStatus.rolledBack,
        deletedMessages: deletedMessages,
        deletedConversations: deletedConversations,
        deletedMemories: deletedMemories,
        deletedPersonaItems: deletedPersonaItems,
        deletedPersonas: deletedPersonas,
        deletedDocuments: 0,
        deletedPending: deletedPending,
        deletedIdMaps: deletedIdMaps,
      );
    });
  }

  // ── 查询 ─────────────────────────────────────────────────────────────────

  Future<List<AstrBotBatchSummary>> batches({int limit = 20}) async {
    final rows = await _db.db.query(
      'astrbot_migration_batches',
      orderBy: 'started_at DESC',
      limit: limit.clamp(1, 200),
    );
    return rows.map((Map<String, Object?> row) {
      return AstrBotBatchSummary(
        id: row['id']! as String,
        isDryRun: ((row['is_dry_run'] as int?) ?? 1) != 0,
        status: (row['status'] as String?) ?? 'pending',
        sourceRef: (row['source_ref'] as String?) ?? '',
        sourceHash: row['source_hash'] as String?,
        startedAt: (row['started_at'] as int?) ?? 0,
        finishedAt: row['finished_at'] as int?,
        error: row['error'] as String?,
        counts: AstrBotImportCounts.fromJson((row['counts_json'] as String?) ?? '{}'),
      );
    }).toList();
  }

  /// 待处理区条目（[batchId] 为 null 时查全部未处理项）
  Future<List<AstrBotPendingItem>> pendingItems({String? batchId, int limit = 100}) async {
    final rows = await _db.db.query(
      'astrbot_import_pending',
      where: batchId == null
          ? 'status = ?'
          : 'batch_id = ?',
      whereArgs: batchId == null ? <Object?>['pending'] : <Object?>[batchId],
      orderBy: batchId == null ? 'created_at DESC, id ASC' : 'created_at ASC, id ASC',
      limit: limit.clamp(1, 500),
    );
    return rows.map(_pendingFromRow).toList();
  }

  AstrBotPendingItem _pendingFromRow(Map<String, Object?> row) {
    return AstrBotPendingItem(
      id: (row['id'] as String?) ?? '',
      batchId: (row['batch_id'] as String?) ?? '',
      entityKind: (row['entity_kind'] as String?) ?? '',
      sourceId: row['source_id'] as String?,
      reasonCode: (row['reason_code'] as String?) ?? '',
      rawJson: (row['raw_json'] as String?) ?? '{}',
      status: (row['status'] as String?) ?? 'pending',
      resolvedTargetId: row['resolved_target_id'] as String?,
      createdAt: (row['created_at'] as int?) ?? 0,
      resolvedAt: row['resolved_at'] as int?,
    );
  }

  /// 按原因批量处理（例如把历史遗留的"系统事件"一次性清掉）
  Future<int> resolvePendingByReason(String reasonCode, {required int atMillis}) async {
    return _db.db.update(
      'astrbot_import_pending',
      <String, Object?>{'status': 'resolved', 'resolved_at': atMillis},
      where: "status = 'pending' AND reason_code = ?",
      whereArgs: <Object?>[reasonCode],
    );
  }

  Future<void> resolvePending(String id, {String? targetId, required int atMillis}) async {
    final rows = await _db.db.query(
      'astrbot_import_pending',
      columns: <String>['status'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) throw AstrBotImportError.pendingNotFound(id);
    if (rows.first['status'] != 'pending') return;
    await _db.db.update(
      'astrbot_import_pending',
      <String, Object?>{
        'status': 'resolved',
        'resolved_target_id': targetId,
        'resolved_at': atMillis,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  // ── 内部 ─────────────────────────────────────────────────────────────────
}

class _ImportOutcome {
  _ImportOutcome(this.counts);
  AstrBotImportCounts counts;
  Map<String, int> pendingByReason = <String, int>{};
  int messagesImportedBefore = 0;
}

// ── 计划结构 ─────────────────────────────────────────────────────────────────

class _PlannedConversation {
  _PlannedConversation(this.id, this.title, this.createdAt, this.updatedAt);
  final String id;
  final String title;
  final int createdAt;
  int updatedAt;
}

class _PlannedMessage {
  _PlannedMessage({
    required this.id,
    required this.clientUuid,
    required this.conversationId,
    required this.role,
    required this.kind,
    required this.text,
    required this.status,
    required this.createdAt,
    required this.sentAt,
    required this.replyToId,
    required this.deletedAt,
    required this.revokedAt,
  });
  final String id;
  final String clientUuid;
  final String conversationId;
  final String role;
  final String kind;
  final String text;
  final String status;
  final int createdAt;
  final int? sentAt;
  String? replyToId;
  final int? deletedAt;
  final int? revokedAt;
}

class _PlannedMemory {
  _PlannedMemory({
    required this.id,
    required this.type,
    required this.title,
    required this.content,
    required this.category,
    required this.dedupeKey,
    required this.sourceId,
    required this.createdAt,
  });
  final String id;
  final String type;
  final String title;
  final String content;
  final String category;
  final String dedupeKey;
  final String sourceId;
  final int createdAt;
}

class _PlannedPersonaItem {
  _PlannedPersonaItem(this.id, this.section, this.key, this.value);
  final String id;
  final String section;
  final String key;
  final String value;
}

class _PlannedPersona {
  _PlannedPersona({
    required this.id,
    required this.name,
    required this.sourcePersonaId,
    required this.items,
    required this.replacesExisting,
  });
  final String id;
  final String name;
  final String sourcePersonaId;
  final List<_PlannedPersonaItem> items;
  final bool replacesExisting;
}

class _PlannedDocument {
  _PlannedDocument({
    required this.id,
    required this.type,
    required this.title,
    required this.content,
    required this.category,
    required this.dedupeKey,
    required this.sourceId,
    required this.createdAt,
  });
  final String id;
  final String type;
  final String title;
  final String content;
  final String category;
  final String dedupeKey;
  final String sourceId;
  final int createdAt;
}

class _PlannedPending {
  _PlannedPending(this.id, this.entityKind, this.sourceId, this.reason, this.rawJson);
  final String id;
  final String entityKind;
  final String? sourceId;
  final AstrBotPendingReason reason;
  final String rawJson;
}

class _ImportPlan {
  _ImportPlan() : counts = AstrBotImportCounts();
  final List<_PlannedConversation> conversations = <_PlannedConversation>[];
  final List<_PlannedMessage> messages = <_PlannedMessage>[];
  final List<_PlannedMemory> memories = <_PlannedMemory>[];
  final List<_PlannedMemory> companionMemories = <_PlannedMemory>[];
  final List<_PlannedDiaryPending> diaries = <_PlannedDiaryPending>[];
  final List<_PlannedMilestonePending> milestones = <_PlannedMilestonePending>[];
  _PlannedPersona? persona;
  final List<_PlannedDocument> documents = <_PlannedDocument>[];
  final List<_PlannedPending> pendings = <_PlannedPending>[];
  final AstrBotImportCounts counts;
}

/// Flutter 版尚无 diary 表：源日记文件先整体进待处理区（P1 建表后启用写入）
class _PlannedDiaryPending {
  _PlannedDiaryPending(this.sourceId, this.rawJson);
  final String sourceId;
  final String rawJson;
}

/// Flutter 版尚无 relationship_milestones 表：先整体进待处理区
class _PlannedMilestonePending {
  _PlannedMilestonePending(this.sourceId, this.rawJson);
  final String sourceId;
  final String rawJson;
}

// ── 源准备（暂存副本 + 指纹）────────────────────────────────────────────────

class _PreparedSources {
  _PreparedSources({
    required this.stagingRoot,
    required this.chatMemoryDatabase,
    required this.longTermMemoryDatabase,
    required this.personaDatabase,
    required this.diaryDirectory,
    required this.lettersDirectory,
    required this.bookNotesDirectory,
    required this.companionLedgerJson,
    required this.configJson,
  });

  final Directory stagingRoot;
  final String? chatMemoryDatabase;
  final String? longTermMemoryDatabase;
  final String? personaDatabase;
  final String? diaryDirectory;
  final String? lettersDirectory;
  final String? bookNotesDirectory;
  final String? companionLedgerJson;
  final String? configJson;

  /// 原件路径 → 导入开始时的指纹
  Map<String, String> originalHashes = <String, String>{};
  String sourceRef = '';
  String sourceHash = '';

  void cleanUpStaging() {
    if (stagingRoot.existsSync()) {
      stagingRoot.deleteSync(recursive: true);
    }
  }

  Future<void> verifyUnchanged() async {
    for (final MapEntry<String, String> entry in originalHashes.entries) {
      final path = entry.key;
      final entity = FileSystemEntity.typeSync(path);
      if (entity == FileSystemEntityType.notFound) {
        throw AstrBotImportError.sourceMissing(path);
      }
      final current = entity == FileSystemEntityType.directory
          ? await sourceDirectoryHash(path)
          : sourceFileHash(path);
      if (current != entry.value) {
        throw AstrBotImportError.sourceChanged(path);
      }
    }
  }
}

// ── 计划构建 ─────────────────────────────────────────────────────────────────

extension _PlanBuilding on AstrBotImporter {
  Future<(String, String)?> _readCorePersona() async {
    final rows = await _db.db.rawQuery('''
      SELECT p.id,
             (SELECT value FROM persona_items i
               WHERE i.persona_id = p.id AND i.section = '核心' AND i.key = 'system_prompt'
               LIMIT 1) AS prompt
        FROM personas p
       WHERE p.kind = 'core'
       ORDER BY p.created_at
       LIMIT 1
    ''');
    if (rows.isEmpty) return null;
    return (
      (rows.first['id'] as String?) ?? '',
      (rows.first['prompt'] as String?) ?? '',
    );
  }

  Future<_ImportPlan> _buildPlan(
    _PreparedSources prepared,
    AstrBotImportOptions options, {
    required String? existingCorePersona,
    required String? existingCorePrompt,
  }) async {
    final plan = _ImportPlan();
    final parser = _SourceDateParser();

    if (prepared.chatMemoryDatabase != null) {
      await _readChat(prepared.chatMemoryDatabase!, options, parser, plan);
    }
    if (prepared.longTermMemoryDatabase != null) {
      await _readMemories(prepared.longTermMemoryDatabase!, parser, plan);
    }
    if (prepared.personaDatabase != null) {
      await _readPersona(
        prepared.personaDatabase!,
        options,
        existingCorePersona: existingCorePersona,
        existingCorePrompt: existingCorePrompt,
        plan: plan,
      );
    }
    if (prepared.diaryDirectory != null) {
      await _readDiary(prepared.diaryDirectory!, parser, plan);
    }
    if (options.importsDocuments) {
      if (prepared.lettersDirectory != null) {
        await _readDocuments(prepared.lettersDirectory!, 'letter', 'letter', plan);
      }
      if (prepared.bookNotesDirectory != null) {
        await _readDocuments(prepared.bookNotesDirectory!, 'book_note', 'book_note', plan);
      }
    }
    if (options.importsRelationshipLedger && prepared.companionLedgerJson != null) {
      await _readCompanionLedger(prepared.companionLedgerJson!, parser, plan);
    }
    if (prepared.configJson != null) {
      await _readConfig(prepared.configJson!, plan);
    }

    plan.counts.pendingTotal = plan.pendings.length;
    final problems = plan.counts.coverageProblems;
    if (problems.isNotEmpty) {
      throw AstrBotImportError.coverageMismatch(problems);
    }
    return plan;
  }

  // MARK: 聊天

  Future<void> _readChat(
    String path,
    AstrBotImportOptions options,
    _SourceDateParser parser,
    _ImportPlan plan,
  ) async {
    final db = await _openReadOnly(path);
    try {
      final tables = (await db.query(
        'sqlite_master',
        columns: <String>['name'],
        where: "type IN ('table','view')",
      ))
          .map((Map<String, Object?> r) => r['name'] as String)
          .toSet();
      if (!tables.contains('chat_memory_records')) {
        throw AstrBotImportError.sourceUnreadable(path);
      }

      final conversationIndex = <String, int>{};
      final sourceMessageIndex = <String, String>{};
      final replyCandidates = <(int, String)>[];

      final rows = await db.query('chat_memory_records', orderBy: 'id');
      plan.counts.sourceChatRecords = rows.length;

      for (final Map<String, Object?> row in rows) {
        final sourceId = row['id']?.toString() ?? '';
        final umo = _string(row, 'umo') ?? '';
        final conversationKey = _string(row, 'conversation_id') ?? '';
        final platform = _string(row, 'platform_name') ?? _string(row, 'platform_id') ?? '聊天';
        final createdAt = _timestamp(row, 'raw_timestamp', _string(row, 'created_at'), parser);
        final role = _string(row, 'role') ?? '';
        final contentKind = _string(row, 'content_kind') ?? '[]';
        final content = _string(row, 'content') ?? '';

        if (contentKind.contains('event')) {
          // 系统事件没有对话价值：不写待确认表，但计入"待处理"以满足覆盖校验
          plan.counts.messagesPending += 1;
          continue;
        }
        if (role != 'user' && role != 'assistant') {
          plan.pendings.add(_plannedPending('chat_record', sourceId, AstrBotPendingReason.unknownRole, row));
          plan.counts.messagesPending += 1;
          continue;
        }
        if (createdAt == null) {
          plan.pendings.add(_plannedPending('chat_record', sourceId, AstrBotPendingReason.invalidTimestamp, row));
          plan.counts.messagesPending += 1;
          continue;
        }
        final text = content.trim();
        if (text.isEmpty) {
          plan.pendings.add(_plannedPending('chat_record', sourceId, AstrBotPendingReason.emptyContent, row));
          plan.counts.messagesPending += 1;
          continue;
        }

        final groupKey = '$umo|$conversationKey';
        String conversationId;
        if (conversationIndex.containsKey(groupKey)) {
          final index = conversationIndex[groupKey]!;
          conversationId = plan.conversations[index].id;
          if (createdAt > plan.conversations[index].updatedAt) {
            plan.conversations[index].updatedAt = createdAt;
          }
        } else {
          conversationId =
              'astrbot-conv-${_hash16(groupKey)}';
          conversationIndex[groupKey] = plan.conversations.length;
          plan.conversations.add(_PlannedConversation(
            conversationId,
            // 带上首条消息日期：同一平台可能有多个历史会话，只看"迁移 · QQ"无法区分
            '${options.conversationTitlePrefix} · $platform · ${_dayKeyOf(createdAt)}',
            createdAt,
            createdAt,
          ));
        }

        String kind;
        if (contentKind.contains('image') || contentKind.contains('file')) {
          kind = contentKind.contains('image') ? 'image' : 'mixed';
          plan.counts.pendingMediaMissing += 1;
          plan.pendings.add(_plannedPending('chat_record', sourceId, AstrBotPendingReason.mediaMissing, row));
        } else {
          kind = 'text';
        }

        final localId = 'astrbot-msg-$sourceId';
        final recalledAt = parser.millis(_string(row, 'recalled_at'));
        final deletedAt = parser.millis(_string(row, 'deleted_at'));

        final message = _PlannedMessage(
          id: localId,
          clientUuid: 'astrbot:chat:$sourceId',
          conversationId: conversationId,
          role: role,
          kind: kind,
          text: text,
          status: recalledAt == null ? 'sent' : 'recalled',
          createdAt: createdAt,
          sentAt: createdAt,
          replyToId: null,
          deletedAt: deletedAt,
          revokedAt: recalledAt,
        );
        final messageIndex = plan.messages.length;
        plan.messages.add(message);
        plan.counts.messagesNew += 1;

        final platformMessageId = _string(row, 'message_id') ?? '';
        if (platformMessageId.isNotEmpty) {
          sourceMessageIndex[platformMessageId] = localId;
        }
        final replyId = _string(row, 'reply_id');
        if (replyId != null && replyId.isNotEmpty) {
          replyCandidates.add((messageIndex, replyId));
        }
      }

      // 第二遍：把平台回复 ID 映射成库内消息 ID
      for (final (int index, String sourceReplyId) in replyCandidates) {
        if (sourceMessageIndex.containsKey(sourceReplyId) && index < plan.messages.length) {
          plan.messages[index].replyToId = sourceMessageIndex[sourceReplyId];
        } else {
          plan.counts.pendingReplyTargetMissing += 1;
          plan.pendings.add(_PlannedPending(
            _uuid.v4(),
            'chat_record',
            plan.messages[index].id,
            AstrBotPendingReason.replyTargetMissing,
            '{"reply_id":"$sourceReplyId"}',
          ));
        }
      }

      // 工具记录：保留原始内容，统一进待处理区
      if (tables.contains('chat_memory_tool_records')) {
        final tools = await db.query('chat_memory_tool_records', orderBy: 'id');
        plan.counts.sourceToolRecords = tools.length;
        for (final Map<String, Object?> row in tools) {
          plan.pendings.add(_plannedPending(
            'tool_record',
            row['id']?.toString(),
            AstrBotPendingReason.toolRecord,
            row,
          ));
          plan.counts.pendingToolRecords += 1;
        }
      }

      // 媒体归档：附件本体已缺失，保留索引元数据
      if (tables.contains('chat_memory_media_archive')) {
        final media = await db.query('chat_memory_media_archive', orderBy: 'created_at');
        plan.counts.sourceMediaArchives = media.length;
        for (final Map<String, Object?> row in media) {
          plan.pendings.add(_plannedPending(
            'media_archive',
            _string(row, 'media_id'),
            AstrBotPendingReason.mediaArchive,
            row,
          ));
          plan.counts.pendingMediaArchives += 1;
        }
      }
    } finally {
      await db.close();
    }
  }

  // MARK: 长期记忆

  Future<void> _readMemories(String path, _SourceDateParser parser, _ImportPlan plan) async {
    final db = await _openReadOnly(path);
    try {
      final tables = (await db.query(
        'sqlite_master',
        columns: <String>['name'],
        where: "type IN ('table','view')",
      ))
          .map((Map<String, Object?> r) => r['name'] as String)
          .toSet();
      if (!tables.contains('mem')) {
        throw AstrBotImportError.sourceUnreadable(path);
      }

      final rows = await db.query('mem', columns: <String>['id', 'kind', 'day', 'text', 'sig'], orderBy: 'id');
      plan.counts.sourceMemories = rows.length;

      for (final Map<String, Object?> row in rows) {
        final sourceId = _string(row, 'sig') ?? row['id']?.toString() ?? '';
        final kind = _string(row, 'kind') ?? 'fact';
        final day = _string(row, 'day') ?? '';
        final text = _string(row, 'text') ?? '';

        if (text.trim().isEmpty) {
          plan.pendings.add(_plannedPending('memory', sourceId, AstrBotPendingReason.emptyContent, row));
          plan.counts.memoriesPending += 1;
          continue;
        }
        final seenAt = parser.dayMillis(day) ?? _leadingDateMillis(text, parser);
        if (seenAt == null) {
          plan.pendings.add(_plannedPending('memory', sourceId, AstrBotPendingReason.invalidDay, row));
          plan.counts.memoriesPending += 1;
          continue;
        }

        final content = text.trim();
        plan.memories.add(_PlannedMemory(
          id: 'astrbot-mem-${_hash16('$sourceId|$content')}',
          type: kind,
          title: content.length > 40 ? content.substring(0, 40) : content,
          content: content,
          category: kind,
          dedupeKey: 'astrbot:mem:$sourceId',
          sourceId: sourceId,
          createdAt: seenAt,
        ));
        plan.counts.memoriesNew += 1;
      }
    } finally {
      await db.close();
    }
  }

  /// AstrBot 的 `mem.day` 存在脏数据（`FACTS`、`YYYY-MM-DD`、甚至正文片段）。
  /// 正文若以 `- 2026-10-24｜...` 形式开头，则以正文里的日期为准；否则判定为未知日期。
  int? _leadingDateMillis(String text, _SourceDateParser parser) {
    var trimmed = text.trim();
    while (trimmed.isNotEmpty &&
        (trimmed.startsWith('-') || trimmed.startsWith(' ') || trimmed.startsWith('\u{FEFF}'))) {
      trimmed = trimmed.substring(1);
    }
    if (trimmed.length < 10) return null;
    return parser.dayMillis(trimmed.substring(0, 10));
  }

  // MARK: 人格

  Future<void> _readPersona(
    String path,
    AstrBotImportOptions options, {
    required String? existingCorePersona,
    required String? existingCorePrompt,
    required _ImportPlan plan,
  }) async {
    final db = await _openReadOnly(path);
    try {
      final tables = (await db.query(
        'sqlite_master',
        columns: <String>['name'],
        where: "type IN ('table','view')",
      ))
          .map((Map<String, Object?> r) => r['name'] as String)
          .toSet();
      if (!tables.contains('personas')) {
        throw AstrBotImportError.sourceUnreadable(path);
      }

      final rows = await db.query('personas', orderBy: 'id');
      plan.counts.sourcePersonaRows = rows.length;
      if (rows.isEmpty) return;

      // 已有核心人格：
      // - 若当前只是首启占位人格，或用户明确选了"替换核心人格"，则原位替换；
      // - 否则一律不覆盖，全部进待处理区。
      final isPlaceholder = existingCorePrompt?.contains('占位核心人格') == true;
      final shouldReplace =
          existingCorePersona != null && (options.replacesCorePersona || isPlaceholder);
      if (existingCorePersona != null && !shouldReplace) {
        for (final Map<String, Object?> row in rows) {
          plan.pendings.add(_plannedPending(
            'persona',
            _string(row, 'persona_id'),
            AstrBotPendingReason.personaConflict,
            row,
          ));
          plan.counts.personaPending += 1;
        }
        return;
      }

      final first = rows.first;
      final sourcePersonaId = _string(first, 'persona_id') ?? 'astrbot';
      final systemPrompt = _string(first, 'system_prompt') ?? '';
      if (systemPrompt.trim().isEmpty) {
        for (final Map<String, Object?> row in rows) {
          plan.pendings.add(_plannedPending(
            'persona',
            _string(row, 'persona_id'),
            AstrBotPendingReason.emptyContent,
            row,
          ));
          plan.counts.personaPending += 1;
        }
        return;
      }

      // 替换时复用现有核心人格 id，避免出现两个 kind='core' 导致读到占位人格
      final personaId = shouldReplace
          ? (existingCorePersona.isEmpty
              ? 'astrbot-persona-${_hash12(sourcePersonaId)}'
              : existingCorePersona)
          : 'astrbot-persona-${_hash12(sourcePersonaId)}';
      final items = <_PlannedPersonaItem>[
        _PlannedPersonaItem(
          'astrbot-persona-item-${_hash12('$sourcePersonaId|system_prompt')}',
          '核心',
          'system_prompt',
          systemPrompt,
        ),
      ];
      final dialogs = _string(first, 'begin_dialogs');
      if (dialogs != null && dialogs.trim() != '[]') {
        items.add(_PlannedPersonaItem(
          'astrbot-persona-item-${_hash12('$sourcePersonaId|begin_dialogs')}',
          '示例对话',
          'begin_dialogs',
          dialogs,
        ));
      }

      plan.persona = _PlannedPersona(
        id: personaId,
        name: options.personaName,
        sourcePersonaId: sourcePersonaId,
        items: items,
        replacesExisting: shouldReplace,
      );
      plan.counts.personaRowsImported += 1;
      plan.counts.personaItemsNew += items.length;

      for (final Map<String, Object?> row in rows.skip(1)) {
        plan.pendings.add(_plannedPending(
          'persona',
          _string(row, 'persona_id'),
          AstrBotPendingReason.personaConflict,
          row,
        ));
        plan.counts.personaPending += 1;
      }
    } finally {
      await db.close();
    }
  }

  // MARK: 日记（Flutter 版无表：整体进待处理区）

  Future<void> _readDiary(String dirPath, _SourceDateParser parser, _ImportPlan plan) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      throw AstrBotImportError.sourceUnreadable(dirPath);
    }

    final files = dir
        .listSync()
        .whereType<File>()
        .where((File f) => ['md', 'txt'].contains(_extensionOf(f.path).toLowerCase()))
        .toList()
      ..sort((File a, File b) => _fileNameOf(a.path).compareTo(_fileNameOf(b.path)));
    plan.counts.sourceDiaryFiles = files.length;

    // `txt/` 子目录是 md 的纯文本镜像：显式计入并跳过，不静默忽略
    final mirrorDir = Directory(_joinPath(dirPath, 'txt'));
    if (mirrorDir.existsSync()) {
      final mirrors = mirrorDir
          .listSync()
          .whereType<File>()
          .where((File f) => _extensionOf(f.path).toLowerCase() == 'txt')
          .length;
      plan.counts.sourceDiaryFiles += mirrors;
      plan.counts.diaryMirrors += mirrors;
    }

    final importedDates = <String>{};

    for (final File file in files) {
      final name = _fileNameOf(file.path);
      final isMirror = _extensionOf(file.path).toLowerCase() == 'txt';
      final baseName = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;

      if (!parser.isValidDate(baseName)) {
        plan.pendings.add(_PlannedPending(
          _uuid.v4(),
          'diary_file',
          name,
          AstrBotPendingReason.unrecognizedDiaryFile,
          _fileRawJson(file),
        ));
        plan.counts.diaryPending += 1;
        continue;
      }

      // `txt/` 目录是 md 的镜像，不重复入库，但必须显式计数
      if (isMirror) {
        plan.counts.diaryMirrors += 1;
        continue;
      }

      final raw = _readTextSafe(file);
      if (raw == null || raw.trim().isEmpty) {
        plan.pendings.add(_PlannedPending(
          _uuid.v4(),
          'diary_file',
          name,
          AstrBotPendingReason.emptyContent,
          _fileRawJson(file),
        ));
        plan.counts.diaryPending += 1;
        continue;
      }
      if (importedDates.contains(baseName)) {
        plan.pendings.add(_PlannedPending(
          _uuid.v4(),
          'diary_file',
          name,
          AstrBotPendingReason.diaryDateConflict,
          _fileRawJson(file),
        ));
        plan.counts.diaryPending += 1;
        continue;
      }
      importedDates.add(baseName);

      // Flutter 版尚无 diary_entries 表：整体进待处理区，原始内容完整保留
      plan.diaries.add(_PlannedDiaryPending(name, _fileRawJson(file)));
      plan.pendings.add(_PlannedPending(
        _uuid.v4(),
        'diary_file',
        name,
        AstrBotPendingReason.featureNotAvailable,
        _fileRawJson(file),
      ));
      plan.counts.diariesNew += 1;
    }
  }

  // MARK: 信件与读书笔记

  Future<void> _readDocuments(String dirPath, String category, String type, _ImportPlan plan) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      throw AstrBotImportError.sourceUnreadable(dirPath);
    }

    final docs = dir
        .listSync()
        .whereType<File>()
        .where((File f) => _extensionOf(f.path).toLowerCase() == 'md')
        .toList()
      ..sort((File a, File b) => _fileNameOf(a.path).compareTo(_fileNameOf(b.path)));
    plan.counts.sourceDocuments += docs.length;

    for (final File file in docs) {
      final name = _fileNameOf(file.path);
      final raw = _readTextSafe(file);
      if (raw == null || raw.trim().isEmpty) {
        plan.pendings.add(_PlannedPending(
          _uuid.v4(),
          category,
          name,
          AstrBotPendingReason.emptyContent,
          _fileRawJson(file),
        ));
        plan.counts.documentsPending += 1;
        continue;
      }
      final parsed = _splitDiary(raw);
      final content =
          parsed.$2.isEmpty ? raw.trim() : parsed.$2;
      // 去重只按正文：真实数据里存在 `最新一封.md` 这类与日期文件逐字节相同的副本
      final contentHash = _hash16(content);
      plan.documents.add(_PlannedDocument(
        id: 'astrbot-doc-$contentHash',
        type: type,
        title: parsed.$1.isEmpty ? _stemOf(name) : parsed.$1,
        content: content,
        category: category,
        dedupeKey: 'astrbot:doc:$category:$contentHash',
        sourceId: '$category:$name',
        createdAt: 0,
      ));
      plan.counts.documentsNew += 1;
    }
  }

  // MARK: 关系账本

  /// `companion_memory.profile` 字段 → 记忆分类。只读映射，不做语义推断。
  static const List<(String, String)> profileFieldCategories = <(String, String)>[
    ('strong_memories', 'relationship'),
    ('weak_preferences', 'preference'),
    ('user_traits', 'fact'),
    ('interests', 'preference'),
    ('boundaries', 'boundary'),
    ('relationship_notes', 'relationship'),
    ('speaking_style', 'preference'),
  ];

  Future<void> _readCompanionLedger(String path, _SourceDateParser parser, _ImportPlan plan) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw AstrBotImportError.sourceUnreadable(path);
    }
    Object? root;
    try {
      root = jsonDecode(await file.readAsString());
    } catch (_) {
      root = null;
    }
    if (root is! Map<String, Object?> || root['users'] is! Map<String, Object?>) {
      throw AstrBotImportError.sourceUnreadable(path);
    }
    final users = root['users'] as Map<String, Object?>;

    plan.counts.sourceLedgerUsers = users.length;
    final companionKeys = <String>{};
    final milestoneKeys = <String>{};

    for (final String identity in users.keys.toList()..sort()) {
      final payload = users[identity];
      if (payload is! Map<String, Object?>) {
        _appendLedgerPending(identity, '{}', plan);
        continue;
      }

      var migratedRows = 0;
      final fallbackAt = _anyMillis(payload['last_activity_at']) ?? _anyMillis(payload['last_seen']) ?? 0;

      // 1. 关系档案：companion_memory.profile 的分组条目
      if (payload['companion_memory'] is Map<String, Object?>) {
        final companionMemory = payload['companion_memory'] as Map<String, Object?>;
        final profileAt = _anyMillis(companionMemory['profile_updated_at']) ?? fallbackAt;
        if (companionMemory['profile'] is Map<String, Object?>) {
          final profile = companionMemory['profile'] as Map<String, Object?>;
          for (final (String field, String category) in profileFieldCategories) {
            if (profile[field] is! List) continue;
            for (final Object? item in profile[field]! as List<Object?>) {
              plan.counts.sourceCompanionMemories += 1;
              final text = (item?.toString() ?? '').trim();
              if (text.isEmpty) {
                plan.counts.companionMemoriesPending += 1;
                continue;
              }
              final key = '$field|$text';
              if (companionKeys.contains(key)) {
                plan.counts.companionMemoriesDuplicate += 1;
                continue;
              }
              companionKeys.add(key);
              plan.companionMemories.add(_PlannedMemory(
                id: 'astrbot-companion-mem-${_hash16(key)}',
                type: category,
                title: text.length > 40 ? text.substring(0, 40) : text,
                content: text,
                category: category,
                dedupeKey: 'astrbot:companion:${_hash16(key)}',
                sourceId: 'companion:$identity:$field:${_hash16(key)}',
                createdAt: profileAt,
              ));
              plan.counts.companionMemoriesNew += 1;
              migratedRows += 1;
            }
          }
        }

        // companion_memory.items：逐条保留 kind/weight 语义
        if (companionMemory['items'] is List) {
          for (final Object? entry in companionMemory['items']! as List<Object?>) {
            plan.counts.sourceCompanionMemories += 1;
            final item = entry is Map<String, Object?> ? entry : <String, Object?>{};
            final text = ((item['text'] as String?) ?? '').trim();
            if (text.isEmpty) {
              plan.counts.companionMemoriesPending += 1;
              continue;
            }
            final kind = ((item['kind'] as String?) ?? 'relationship').toLowerCase();
            final key = 'items|$kind|$text';
            if (companionKeys.contains(key)) {
              plan.counts.companionMemoriesDuplicate += 1;
              continue;
            }
            companionKeys.add(key);
            plan.companionMemories.add(_PlannedMemory(
              id: 'astrbot-companion-mem-${_hash16(key)}',
              type: kind,
              title: text.length > 40 ? text.substring(0, 40) : text,
              content: text,
              category: _memoryCategory(forItemKind: kind),
              dedupeKey: 'astrbot:companion:${_hash16(key)}',
              sourceId: 'companion:$identity:items:${_hash16(key)}',
              createdAt: _anyMillis(item['created_ts']) ?? fallbackAt,
            ));
            plan.counts.companionMemoriesNew += 1;
            migratedRows += 1;
          }
        }
      }

      // 2. 未结约定：open_loops → promise 记忆
      if (payload['open_loops'] is List) {
        for (final Object? entry in payload['open_loops']! as List<Object?>) {
          plan.counts.sourceCompanionMemories += 1;
          final loop = entry is Map<String, Object?> ? entry : <String, Object?>{};
          final text = ((loop['text'] as String?) ?? '').trim();
          if (text.isEmpty) {
            plan.counts.companionMemoriesPending += 1;
            continue;
          }
          final key = 'open_loop|$text';
          if (companionKeys.contains(key)) {
            plan.counts.companionMemoriesDuplicate += 1;
            continue;
          }
          companionKeys.add(key);
          plan.companionMemories.add(_PlannedMemory(
            id: 'astrbot-companion-mem-${_hash16(key)}',
            type: 'promise',
            title: text.length > 40 ? text.substring(0, 40) : text,
            content: text,
            category: 'promise',
            dedupeKey: 'astrbot:companion:${_hash16(key)}',
            sourceId: 'companion:$identity:open_loops:${_hash16(key)}',
            createdAt: _anyMillis(loop['created_ts']) ??
                parser.millis(loop['created_at'] as String?) ??
                fallbackAt,
          ));
          plan.counts.companionMemoriesNew += 1;
          migratedRows += 1;
        }
      }

      // 3. 对话剧集 → 共同经历里程碑（Flutter 版无表：进待处理区）
      if (payload['dialogue_episodes'] is List) {
        for (final Object? entry in payload['dialogue_episodes']! as List<Object?>) {
          plan.counts.sourceRelationshipMilestones += 1;
          final episode = entry is Map<String, Object?> ? entry : <String, Object?>{};
          final summary = ((episode['summary'] as String?) ?? '').trim();
          if (summary.isEmpty) {
            plan.counts.relationshipMilestonesPending += 1;
            continue;
          }
          final day = (episode['date'] as String?) ?? '';
          final key = 'episode|$day|$summary';
          if (milestoneKeys.contains(key)) {
            plan.counts.relationshipMilestonesDuplicate += 1;
            continue;
          }
          milestoneKeys.add(key);
          plan.milestones.add(_PlannedMilestonePending(key, jsonEncode(episode)));
          plan.pendings.add(_PlannedPending(
            _uuid.v4(),
            'relationship_milestone',
            key,
            AstrBotPendingReason.featureNotAvailable,
            jsonEncode(episode),
          ));
          plan.counts.relationshipMilestonesNew += 1;
          migratedRows += 1;
        }
      }

      // 4. 关系违规 / 修复 → 重要转折里程碑（Flutter 版无表：进待处理区）
      if (payload['relationship_ledger'] is List) {
        for (final Object? entry in payload['relationship_ledger']! as List<Object?>) {
          final event = entry is Map<String, Object?> ? entry : <String, Object?>{};
          final reason = ((event['reason_code'] as String?) ?? '').toLowerCase();
          if (!reason.contains('violation')) continue;
          plan.counts.sourceRelationshipMilestones += 1;
          final key = 'ledger|${event['event_key']?.toString() ?? ''}|$reason';
          if (milestoneKeys.contains(key)) {
            plan.counts.relationshipMilestonesDuplicate += 1;
            continue;
          }
          milestoneKeys.add(key);
          plan.milestones.add(_PlannedMilestonePending(key, jsonEncode(event)));
          plan.pendings.add(_PlannedPending(
            _uuid.v4(),
            'relationship_milestone',
            key,
            AstrBotPendingReason.featureNotAvailable,
            jsonEncode(event),
          ));
          plan.counts.relationshipMilestonesNew += 1;
          migratedRows += 1;
        }
      }

      if (migratedRows == 0) {
        _appendLedgerPending(identity, jsonEncode(payload), plan);
      } else {
        plan.counts.relationshipUsersImported += 1;
      }
    }
  }

  /// 无法迁移的用户（空档案/格式不符）进待处理区，原始内容完整保留
  void _appendLedgerPending(String identity, String raw, _ImportPlan plan) {
    plan.pendings.add(_PlannedPending(
      _uuid.v4(),
      'relationship_ledger',
      identity,
      AstrBotPendingReason.relationshipLedger,
      raw,
    ));
    plan.counts.ledgerPending += 1;
  }

  /// 记忆分类白名单：fact / preference / relationship / boundary / promise / identity / value / emotion_pattern / event
  String _memoryCategory({required String forItemKind}) {
    const allowed = <String>[
      'fact', 'preference', 'relationship', 'boundary', 'promise',
      'identity', 'value', 'emotion_pattern', 'event',
    ];
    return allowed.contains(forItemKind) ? forItemKind : 'relationship';
  }

  // MARK: 主配置留档

  /// AstrBot `data/cmd_config.json`：含模型、压缩、分段回复、插件参数。
  /// 只做**脱敏留档**进待处理区，不自动套用到本 App 配置。
  Future<void> _readConfig(String path, _ImportPlan plan) async {
    plan.counts.sourceConfigFiles += 1;
    const fallback = '{"note":"cmd_config.json 无法解析，仅记录存在"}';
    Object? root;
    try {
      root = jsonDecode(await File(path).readAsString());
    } catch (_) {
      root = null;
    }
    if (root is! Map<String, Object?>) {
      plan.pendings.add(_PlannedPending(
        _uuid.v4(),
        'config',
        'cmd_config.json',
        AstrBotPendingReason.unsupportedConfig,
        fallback,
      ));
      plan.counts.configPending += 1;
      return;
    }
    final redacted = _redactedValue(root);
    final rawJson = jsonEncode(redacted);
    plan.pendings.add(_PlannedPending(
      _uuid.v4(),
      'config',
      'cmd_config.json',
      AstrBotPendingReason.unsupportedConfig,
      rawJson,
    ));
    plan.counts.configPending += 1;
  }

  /// 递归脱敏：形如 key/token/secret/password 的字段一律替换；超长文本截断
  Object? _redactedValue(Object? value) {
    if (value is Map<String, Object?>) {
      final output = <String, Object?>{};
      value.forEach((String key, Object? item) {
        final lowered = key.toLowerCase();
        if (lowered.contains('key') ||
            lowered.contains('token') ||
            lowered.contains('secret') ||
            lowered.contains('password')) {
          output[key] = '<redacted>';
        } else {
          output[key] = _redactedValue(item);
        }
      });
      return output;
    }
    if (value is List) {
      return value.map(_redactedValue).toList();
    }
    if (value is String && value.length > 200) {
      return '${value.substring(0, 200)}…';
    }
    return value;
  }

  _PlannedPending _plannedPending(
    String kind,
    String? sourceId,
    AstrBotPendingReason reason,
    Map<String, Object?> row,
  ) {
    return _PlannedPending(
      _uuid.v4(),
      kind,
      sourceId,
      reason,
      _rowRawJson(row),
    );
  }
}

// ── 事务内写入 ───────────────────────────────────────────────────────────────

extension _Transaction on AstrBotImporter {
  Future<void> _apply(
    DatabaseExecutor txn,
    _ImportPlan plan,
    String batchId,
    int now,
    _ImportOutcome outcome,
  ) async {
    outcome.messagesImportedBefore = await _count(
      txn,
      "SELECT count(*) AS n FROM messages WHERE client_uuid LIKE 'astrbot:chat:%'",
    );

    // 会话
    for (final _PlannedConversation conversation in plan.conversations) {
      final exists = await _count(txn, 'SELECT count(*) AS n FROM conversations WHERE id = ?',
          <Object?>[conversation.id]);
      if (exists > 0) continue;
      await txn.execute(
        'INSERT INTO conversations (id, title, kind, created_at, updated_at) '
        "VALUES (?, ?, 'imported', ?, ?)",
        <Object?>[conversation.id, conversation.title, conversation.createdAt, conversation.updatedAt],
      );
      await _map(txn, batchId: batchId, kind: 'conversation', sourceId: conversation.id, targetId: conversation.id, at: now);
    }

    // 消息
    for (final _PlannedMessage message in plan.messages) {
      final existing = await txn.query(
        'messages',
        columns: <String>['id'],
        where: 'client_uuid = ?',
        whereArgs: <Object?>[message.clientUuid],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        outcome.counts.messagesNew -= 1;
        outcome.counts.messagesDuplicate += 1;
        // 重复行不写 id_map：回滚只能删"本批次造出来的行"，绝不能删既有消息
        continue;
      }
      await txn.execute(
        '''
        INSERT INTO messages
            (id, client_uuid, conversation_id, role, kind, text, status, origin,
             reply_to_id, created_at, sent_at, deleted_at, revoked_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 'imported', ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          message.id, message.clientUuid, message.conversationId, message.role,
          message.kind, message.text, message.status, message.replyToId,
          message.createdAt, message.sentAt, message.deletedAt, message.revokedAt,
        ],
      );
      await _map(txn, batchId: batchId, kind: 'message', sourceId: message.id, targetId: message.id, at: now);
    }

    // 会话时间对齐：把 updated_at 提到该会话最后一条消息的时间，
    // 否则会话列表按 updated_at 排序会把导入会话压到最底部，看起来像"没导入"。
    for (final _PlannedConversation conversation in plan.conversations) {
      await txn.execute(
        '''
        UPDATE conversations
        SET updated_at = max(updated_at, COALESCE(
            (SELECT max(m.created_at) FROM messages m
              WHERE m.conversation_id = conversations.id AND m.deleted_at IS NULL),
            updated_at))
        WHERE id = ?
        ''',
        <Object?>[conversation.id],
      );
    }

    // 记忆
    final memoryCountBefore = await _count(
      txn,
      "SELECT count(*) AS n FROM memories WHERE dedupe_key LIKE 'astrbot:%'",
    );
    for (final _PlannedMemory memory in plan.memories) {
      final existing = await txn.query(
        'memories',
        columns: <String>['id'],
        where: "scope = 'shared' AND dedupe_key = ? AND deleted_at IS NULL",
        whereArgs: <Object?>[memory.dedupeKey],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        outcome.counts.memoriesNew -= 1;
        outcome.counts.memoriesDuplicate += 1;
        continue;
      }
      await _insertMemory(txn, memory, batchId: batchId, now: now);
      await _map(txn, batchId: batchId, kind: 'memory', sourceId: memory.sourceId, targetId: memory.id, at: now);
    }

    // 关系档案记忆（companion_memory / open_loops）：与 memories 同表，单独计数以便追溯
    for (final _PlannedMemory memory in plan.companionMemories) {
      final existing = await txn.query(
        'memories',
        columns: <String>['id'],
        where: 'dedupe_key = ?',
        whereArgs: <Object?>[memory.dedupeKey],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        outcome.counts.companionMemoriesNew -= 1;
        outcome.counts.companionMemoriesDuplicate += 1;
        continue;
      }
      await _insertMemory(
        txn,
        memory,
        batchId: batchId,
        now: now,
        createdAtOverride: memory.createdAt == 0 ? now : memory.createdAt,
      );
      await _map(txn, batchId: batchId, kind: 'memory', sourceId: memory.sourceId, targetId: memory.id, at: now);
    }
    final memoryCountAfter = await _count(
      txn,
      "SELECT count(*) AS n FROM memories WHERE dedupe_key LIKE 'astrbot:%'",
    );
    final expectedMemories = outcome.counts.memoriesNew + outcome.counts.companionMemoriesNew;
    if (memoryCountAfter - memoryCountBefore != expectedMemories) {
      throw AstrBotImportError.coverageMismatch(<String>[
        '记忆写入数不符：期望 $expectedMemories，实际 ${memoryCountAfter - memoryCountBefore}',
      ]);
    }

    // 文档（信件 / 读书笔记）
    for (final _PlannedDocument document in plan.documents) {
      final existing = await txn.query(
        'memories',
        columns: <String>['id'],
        where: "scope = 'shared' AND dedupe_key = ? AND deleted_at IS NULL",
        whereArgs: <Object?>[document.dedupeKey],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        outcome.counts.documentsNew -= 1;
        outcome.counts.documentsDuplicate += 1;
        continue;
      }
      await _insertMemory(
        txn,
        _PlannedMemory(
          id: document.id,
          type: document.type,
          title: document.title,
          content: document.content,
          category: document.category,
          dedupeKey: document.dedupeKey,
          sourceId: document.sourceId,
          createdAt: document.createdAt == 0 ? now : document.createdAt,
        ),
        batchId: batchId,
        now: now,
      );
      await _map(txn, batchId: batchId, kind: 'document', sourceId: document.sourceId, targetId: document.id, at: now);
    }

    // 人格
    final persona = plan.persona;
    if (persona != null) {
      if (persona.replacesExisting) {
        // 原位替换：不新建第二个 kind='core'，否则读取端仍可能拿到旧占位人格
        await txn.execute(
          'UPDATE personas SET name = ?, updated_at = ? WHERE id = ?',
          <Object?>[persona.name, now, persona.id],
        );
      } else {
        await txn.execute(
          '''
          INSERT INTO personas
              (id, kind, name, is_locked, current_version, created_at, updated_at)
          VALUES (?, 'core', ?, 1, 1, ?, ?)
          ''',
          <Object?>[persona.id, persona.name, now, now],
        );
      }
      for (final _PlannedPersonaItem item in persona.items) {
        // 实际落库的行 id：原位替换 UPDATE 命中已有行时，
        // 必须改用已有行的 id，否则 tier_history / 映射表会引用不存在的 item id
        var targetItemId = item.id;
        var needsInsert = !persona.replacesExisting;
        if (persona.replacesExisting) {
          await txn.execute(
            "UPDATE persona_items SET value = ?, source = 'astrbot', updated_at = ? "
            'WHERE persona_id = ? AND section = ? AND key = ?',
            <Object?>[item.value, now, persona.id, item.section, item.key],
          );
          final changed = await txn.rawQuery('SELECT changes() AS c');
          final changedCount = ((changed.first['c'] as int?) ?? 0);
          needsInsert = changedCount == 0;
          if (!needsInsert) {
            final rows = await txn.query(
              'persona_items',
              columns: <String>['id'],
              where: 'persona_id = ? AND section = ? AND key = ?',
              whereArgs: <Object?>[persona.id, item.section, item.key],
              limit: 1,
            );
            targetItemId = (rows.first['id'] as String?) ?? item.id;
          }
        }
        if (needsInsert) {
          await txn.execute(
            '''
            INSERT INTO persona_items
                (id, persona_id, section, key, value, confidence, weight, source, updated_at,
                 tier, tier_status, tier_source, tier_evidence, status)
            VALUES (?, ?, ?, ?, ?, 1.0, 1.0, 'astrbot', ?, 'core', 'core', 'astrbot_import', ?, 'active')
            ''',
            <Object?>[
              item.id, persona.id, item.section, item.key, item.value, now,
              '{"source":"astrbot","persona":"${persona.sourcePersonaId}"}',
            ],
          );
        }
        // tier 历史：Flutter 版 persona_item_tier_history 列与原版一致
        await txn.execute(
          '''
          INSERT INTO persona_item_tier_history
              (id, item_id, from_tier, to_tier, from_status, to_status, reason, evidence_json,
               decided_by, created_at)
          VALUES (?, ?, NULL, 'core', NULL, 'core', 'astrbot_import', '{}', 'migration', ?)
          ''',
          <Object?>[_uuid.v4(), targetItemId, now],
        );
        await _map(txn, batchId: batchId, kind: 'persona_item', sourceId: item.key, targetId: targetItemId, at: now);
      }
      // 版本快照
      await txn.execute(
        '''
        INSERT INTO persona_versions
            (id, persona_id, version, snapshot_json, change_reason, changed_by, created_at)
        VALUES (?, ?, 1, ?, 'AstrBot 迁移导入', 'migration', ?)
        ''',
        <Object?>[_uuid.v4(), persona.id, _personaSnapshot(persona), now],
      );
      await _map(txn, batchId: batchId, kind: 'persona', sourceId: persona.sourcePersonaId, targetId: persona.id, at: now);
    }

    // 待处理区
    for (final _PlannedPending item in plan.pendings) {
      await txn.execute(
        '''
        INSERT INTO astrbot_import_pending
            (id, batch_id, entity_kind, source_id, reason_code, raw_json, status, created_at)
        VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
        ''',
        <Object?>[item.id, batchId, item.entityKind, item.sourceId, item.reason.value, item.rawJson, now],
      );
      outcome.pendingByReason[item.reason.value] =
          (outcome.pendingByReason[item.reason.value] ?? 0) + 1;
    }
  }

  /// 记忆写入（memories + memory_versions + memory_sources + memory_fts 回填）
  Future<void> _insertMemory(
    DatabaseExecutor txn,
    _PlannedMemory memory, {
    required String batchId,
    required int now,
    int? createdAtOverride,
  }) async {
    final createdAt = createdAtOverride ?? memory.createdAt;
    await txn.execute(
      '''
      INSERT INTO memories
          (id, type, title, content, importance, salience, confidence, status, first_seen_at,
           scope, layer, category, source_kind, epistemic_status, version, dedupe_key, heat,
           classification_status, created_at, updated_at, importance_score, importance_source,
           importance_source_at, original_external_id, original_content, original_created_at,
           import_batch_id, classification_evidence_json)
      VALUES (?, ?, ?, ?, 'normal', 0.5, 0.5, 'active', ?,
              'shared', 'semantic', ?, 'astrbot_import', 'observed', 1, ?, 'warm',
              'pending', ?, ?, 0.5, 'legacy_text', ?, ?, ?, ?, ?, '[]')
      ''',
      <Object?>[
        memory.id, memory.type, memory.title, memory.content, createdAt,
        memory.category, memory.dedupeKey,
        createdAt, createdAt, now, memory.sourceId, memory.content, createdAt, batchId,
      ],
    );
    await txn.execute(
      '''
      INSERT INTO memory_versions
          (id, memory_id, version, title, content, change_reason, changed_by, source_kind, created_at)
      VALUES (?, ?, 1, ?, ?, 'AstrBot 迁移导入', 'migration', 'astrbot_import', ?)
      ''',
      <Object?>[_uuid.v4(), memory.id, memory.title, memory.content, createdAt],
    );
    await txn.execute(
      '''
      INSERT INTO memory_sources (id, memory_id, source_type, source_id, excerpt, at, created_at)
      VALUES (?, ?, 'astrbot_memory', ?, ?, ?, ?)
      ''',
      <Object?>[
        _uuid.v4(), memory.id, memory.sourceId,
        memory.content.length > 200 ? memory.content.substring(0, 200) : memory.content,
        createdAt, createdAt,
      ],
    );
    await txn.execute(
      "INSERT INTO memory_fts (memory_id, scope, text_bigram) VALUES (?, 'shared', ?)",
      <Object?>[memory.id, bigram('${memory.title} ${memory.content}')],
    );
  }

  Future<void> _map(
    DatabaseExecutor txn, {
    required String batchId,
    required String kind,
    required String sourceId,
    required String targetId,
    required int at,
  }) async {
    await txn.execute(
      '''
      INSERT INTO astrbot_id_map (id, batch_id, entity_kind, source_id, target_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      <Object?>[_uuid.v4(), batchId, kind, sourceId, targetId, at],
    );
  }

  String _personaSnapshot(_PlannedPersona persona) {
    return jsonEncode(<String, Object?>{
      'name': persona.name,
      'items': persona.items
          .map((_PlannedPersonaItem i) =>
              <String, String>{'section': i.section, 'key': i.key, 'value': i.value})
          .toList(),
    });
  }

  Future<int> _count(DatabaseExecutor txn, String sql, [List<Object?>? args]) async {
    final rows = await txn.rawQuery(sql, args);
    return rows.isEmpty ? 0 : ((rows.first['n'] as int?) ?? 0);
  }
}

// ── 校验 ─────────────────────────────────────────────────────────────────────

extension _Validation on AstrBotImporter {
  Future<void> _verifyPostconditions(
    DatabaseExecutor txn,
    _ImportPlan plan,
    _ImportOutcome outcome,
    String legacyBefore,
  ) async {
    final problems = outcome.counts.coverageProblems;
    if (problems.isNotEmpty) {
      throw AstrBotImportError.coverageMismatch(problems);
    }

    final importedMessages = await _count(
      txn,
      "SELECT count(*) AS n FROM messages WHERE client_uuid LIKE 'astrbot:chat:%'",
    );
    if (importedMessages - outcome.messagesImportedBefore != outcome.counts.messagesNew) {
      throw AstrBotImportError.coverageMismatch(<String>[
        '消息写入数不符：期望 ${outcome.counts.messagesNew}，实际 ${importedMessages - outcome.messagesImportedBefore}',
      ]);
    }

    final legacyAfter = await _legacyFingerprint(txn);
    if (legacyAfter != legacyBefore) {
      throw AstrBotImportError.coverageMismatch(<String>['既有数据内容指纹发生变化（导入只增不覆盖）']);
    }

    final quick = (await txn.rawQuery('PRAGMA quick_check')).first.values.first.toString();
    if (quick.toLowerCase() != 'ok') {
      throw AstrBotImportError.coverageMismatch(<String>['quick_check 失败：$quick']);
    }
  }

  /// 只覆盖"非本导入器写入"的行，用于证明导入没有改动既有数据。
  ///
  /// 核心人格条目不参与指纹：原位替换复用占位人格的 UUID id，
  /// 其条目变化属于预期行为而非数据破坏。
  Future<String> _legacyFingerprint(DatabaseExecutor txn) async {
    final buffer = StringBuffer();
    buffer.write(await _legacyLines(txn, '''
      SELECT quote(id) || '|' || quote(title) || '|' || quote(kind) || '|' || quote(coalesce(archived_at, -1)) AS line
        FROM conversations WHERE id NOT LIKE 'astrbot-%' ORDER BY id
    '''));
    buffer.write(await _legacyLines(txn, '''
      SELECT quote(id) || '|' || quote(text) || '|' || quote(status) || '|' || quote(kind)
             || '|' || quote(coalesce(deleted_at, -1)) || '|' || quote(coalesce(revoked_at, -1)) AS line
        FROM messages WHERE id NOT LIKE 'astrbot-%' ORDER BY id
    '''));
    buffer.write(await _legacyLines(txn, '''
      SELECT quote(id) || '|' || quote(content) || '|' || quote(scope) || '|' || quote(status) AS line
        FROM memories WHERE id NOT LIKE 'astrbot-%' ORDER BY id
    '''));
    buffer.write(await _legacyLines(txn, '''
      SELECT quote(id) || '|' || quote(value) AS line FROM persona_items
       WHERE persona_id NOT LIKE 'astrbot-%'
         AND persona_id NOT IN (SELECT id FROM personas WHERE kind = 'core')
       ORDER BY id
    '''));
    return sha256.convert(utf8.encode(buffer.toString())).toString();
  }

  Future<String> _legacyLines(DatabaseExecutor txn, String sql) async {
    final lines =
        (await txn.rawQuery(sql)).map((Map<String, Object?> r) => r['line']?.toString() ?? '');
    return '${lines.join('\u{1E}')}\u{1F}';
  }
}

// ── 批次读写 ─────────────────────────────────────────────────────────────────

extension _BatchIO on AstrBotImporter {
  Future<void> _insertBatch(
    DatabaseExecutor txn, {
    required String batchId,
    required AstrBotImportStatus status,
    required bool isDryRun,
    required String sourceRef,
    required String sourceHash,
    required int startedAt,
    required AstrBotImportCounts counts,
    required String? error,
  }) async {
    await txn.execute(
      '''
      INSERT INTO astrbot_migration_batches
          (id, source_kind, source_ref, source_hash, is_dry_run, status, options_json,
           counts_json, checkpoint_json, started_at, finished_at, error)
      VALUES (?, 'astrbot', ?, ?, ?, ?, '{}', ?, '{}', ?, NULL, ?)
      ''',
      <Object?>[
        batchId, sourceRef, sourceHash, isDryRun ? 1 : 0,
        status.value, jsonEncode(counts.toJson()), startedAt, error,
      ],
    );
  }

  Future<void> _updateBatchFinished(
    DatabaseExecutor txn, {
    required String batchId,
    required AstrBotImportStatus status,
    required int finishedAt,
    required AstrBotImportCounts counts,
    required String? error,
  }) async {
    await txn.execute(
      '''
      UPDATE astrbot_migration_batches
         SET status = ?, finished_at = ?, counts_json = ?, error = ?
       WHERE id = ?
      ''',
      <Object?>[status.value, finishedAt, jsonEncode(counts.toJson()), error, batchId],
    );
  }

  /// 失败留痕：已有批次就改成 failed，没有才新建，避免主键冲突丢记录。
  Future<void> _recordFailure({
    required String batchId,
    required bool isDryRun,
    required String sourceRef,
    required String sourceHash,
    required int startedAt,
    required AstrBotImportCounts counts,
    required String error,
  }) async {
    final finishedAt = _now();
    await _db.db.transaction((DatabaseExecutor txn) async {
      await txn.execute(
        '''
        UPDATE astrbot_migration_batches
           SET status = ?, finished_at = ?, counts_json = ?, error = ?
         WHERE id = ?
        ''',
        <Object?>[
          AstrBotImportStatus.failed.value, finishedAt, jsonEncode(counts.toJson()), error, batchId,
        ],
      );
      final changed = ((await txn.rawQuery('SELECT changes() AS c')).first['c'] as int?) ?? 0;
      if (changed > 0) return;
      await _insertBatch(
        txn,
        batchId: batchId,
        status: AstrBotImportStatus.failed,
        isDryRun: isDryRun,
        sourceRef: sourceRef,
        sourceHash: sourceHash,
        startedAt: startedAt,
        counts: counts,
        error: error,
      );
      await _updateBatchFinished(
        txn,
        batchId: batchId,
        status: AstrBotImportStatus.failed,
        finishedAt: finishedAt,
        counts: counts,
        error: error,
      );
    });
  }
}

// ── 源准备与只读打开 ─────────────────────────────────────────────────────────

extension _SourcePrep on AstrBotImporter {
  Future<_PreparedSources> _prepareSources(AstrBotSourcePaths source) async {
    final stagingRoot = Directory(
      _joinPath(
        Directory.systemTemp.path,
        'astrbot-import-${_uuid.v4()}',
      ),
    );
    stagingRoot.createSync(recursive: true);
    final hashes = <String, String>{};

    Future<String?> stage(String? path) async {
      if (path == null) return null;
      final entity = FileSystemEntity.typeSync(path);
      if (entity == FileSystemEntityType.notFound) {
        throw AstrBotImportError.sourceMissing(path);
      }
      final isDirectory = entity == FileSystemEntityType.directory;
      hashes[path] = isDirectory ? await sourceDirectoryHash(path) : sourceFileHash(path);
      if (!isDirectory && _extensionOf(path) == 'db') {
        // WAL 库：连同 -wal/-shm 的指纹一起记录，避免丢掉未 checkpoint 的事务
        for (final String suffix in <String>['-wal', '-shm']) {
          final sidecar = File('$path$suffix');
          if (sidecar.existsSync()) {
            hashes[sidecar.path] = sourceFileHash(sidecar.path);
          }
        }
      }
      final name = isDirectory ? _uuid.v4() : _uuid.v4();
      final destination = _joinPath(stagingRoot.path, name);
      if (isDirectory) {
        await _copyDirectory(Directory(path), Directory(destination));
        // .db 目录内可能出现 sidecar，一并复制
        for (final String suffix in <String>['-wal', '-shm']) {
          final sidecar = File('$path$suffix');
          if (sidecar.existsSync()) {
            await sidecar.copy('$destination$suffix');
          }
        }
      } else {
        await File(path).copy(destination);
        if (_extensionOf(path) == 'db') {
          for (final String suffix in <String>['-wal', '-shm']) {
            final sidecar = File('$path$suffix');
            if (sidecar.existsSync()) {
              await sidecar.copy('$destination$suffix');
            }
          }
        }
      }
      return destination;
    }

    String? chatDb;
    String? memoryDb;
    String? personaDb;
    String? diaryDir;
    String? lettersDir;
    String? bookNotesDir;
    String? ledgerJson;
    String? configJson;
    try {
      chatDb = await stage(source.chatMemoryDatabase);
      memoryDb = await stage(source.longTermMemoryDatabase);
      personaDb = await stage(source.personaDatabase);
      diaryDir = await stage(source.diaryDirectory);
      lettersDir = await stage(source.lettersDirectory);
      bookNotesDir = await stage(source.bookNotesDirectory);
      ledgerJson = await stage(source.companionLedgerJson);
      configJson = await stage(source.configJson);
    } on AstrBotImportError {
      if (stagingRoot.existsSync()) stagingRoot.deleteSync(recursive: true);
      rethrow;
    } catch (_) {
      if (stagingRoot.existsSync()) stagingRoot.deleteSync(recursive: true);
      rethrow;
    }

    final combinedEntries = hashes.entries
        .toList()
      ..sort((MapEntry<String, String> a, MapEntry<String, String> b) => a.key.compareTo(b.key));
    final combinedString =
        combinedEntries.map((MapEntry<String, String> e) => '${e.key}:${e.value}').join('\n');
    final hash = sha256.convert(utf8.encode(combinedString)).toString();

    return _PreparedSources(
      stagingRoot: stagingRoot,
      chatMemoryDatabase: chatDb,
      longTermMemoryDatabase: memoryDb,
      personaDatabase: personaDb,
      diaryDirectory: diaryDir,
      lettersDirectory: lettersDir,
      bookNotesDirectory: bookNotesDir,
      companionLedgerJson: ledgerJson,
      configJson: configJson,
    )
      ..originalHashes = hashes
      ..sourceHash = hash
      ..sourceRef = _fileNameOf(
        source.chatMemoryDatabase ??
            source.longTermMemoryDatabase ??
            source.personaDatabase ??
            'astrbot',
      );
  }

  /// 只读打开源 SQLite（先复制到暂存目录，原件不触碰）
  Future<Database> _openReadOnly(String path) async {
    try {
      return await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          readOnly: true,
          onCreate: (Database db, int version) async {},
        ),
      );
    } catch (_) {
      throw AstrBotImportError.sourceUnreadable(path);
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final FileSystemEntity entity in source.list()) {
      final target = _joinPath(destination.path, _fileNameOf(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(target));
      } else if (entity is File) {
        await entity.copy(target);
      }
    }
  }
}

// ── 源日期解析（UTC+8）───────────────────────────────────────────────────────

/// `2026-10-24 01:47:38.052761` → 毫秒（源库时间按 UTC+8 解释）
class _SourceDateParser {
  /// 北京时间字符串 → epoch 毫秒
  int? millis(String? text) {
    if (text == null) return null;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final dot = trimmed.indexOf('.');
    final base = dot < 0 ? trimmed : trimmed.substring(0, dot);
    final match = _dateTimePattern.firstMatch(base);
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final second = int.parse(match.group(6)!);
    var millis = DateTime.utc(year, month, day, hour - 8, minute, second)
        .millisecondsSinceEpoch;
    if (dot >= 0) {
      final fraction = double.tryParse('0.${trimmed.substring(dot + 1)}');
      if (fraction != null) {
        millis += (fraction * 1000).round();
      }
    }
    return millis;
  }

  /// `yyyy-MM-dd` → 当天 00:00 毫秒（UTC+8）；非法日期返回 null
  int? dayMillis(String day) {
    if (!isValidDate(day)) return null;
    final match = _dateOnlyPattern.firstMatch(day);
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final dayOfMonth = int.parse(match.group(3)!);
    return DateTime.utc(year, month, dayOfMonth, -8).millisecondsSinceEpoch;
  }

  /// `yyyy-MM-dd` 合法性（含真实日期校验）
  bool isValidDate(String text) {
    final match = _dateOnlyPattern.firstMatch(text.trim());
    if (match == null || match.group(0) != text.trim()) return false;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return false;
    final normalized = DateTime(year, month, day);
    return normalized.year == year && normalized.month == month && normalized.day == day;
  }

  static final RegExp _dateTimePattern =
      RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$');
  static final RegExp _dateOnlyPattern = RegExp(r'(\d{4})-(\d{2})-(\d{2})');
}

// ── 小工具 ───────────────────────────────────────────────────────────────────

String? _string(Map<String, Object?> row, String column) {
  final value = row[column];
  return value is String ? value : null;
}

/// 源文件 SHA256 指纹
String sourceFileHash(String path) {
  return sha256.convert(File(path).readAsBytesSync()).toString();
}

/// 源目录指纹：相对路径 + 各文件指纹，排序后整体哈希
Future<String> sourceDirectoryHash(String path) async {
  final dir = Directory(path);
  final entries = <String>[];
  await for (final FileSystemEntity entity in dir.list(recursive: true)) {
    if (entity is File) {
      final relative = entity.path.replaceFirst(path, '');
      entries.add('$relative:${sourceFileHash(entity.path)}');
    }
  }
  entries.sort();
  return sha256.convert(utf8.encode(entries.join('\n'))).toString();
}

/// JSON 动态值 → 秒（>0）→ 毫秒
int? _anyMillis(Object? value) {
  final seconds = _anyDouble(value);
  if (seconds == null || seconds <= 0) return null;
  return (seconds * 1000).round();
}

/// JSON 动态值 → double（数字或数字字符串）
double? _anyDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// raw_timestamp（秒）优先，回退 created_at 文本
int? _timestamp(
  Map<String, Object?> row,
  String rawColumn,
  String? text,
  _SourceDateParser parser,
) {
  final raw = row[rawColumn];
  if (raw is num && raw > 0) {
    return (raw * 1000).round();
  }
  return parser.millis(text);
}

/// 首行 `# 标题` 作标题，其余为正文
(String, String) _splitDiary(String raw) {
  final normalized = raw.startsWith('\u{FEFF}') ? raw.substring(1) : raw;
  final lines = normalized.split(RegExp(r'\r?\n'));
  var title = '';
  if (lines.isNotEmpty && lines.first.startsWith('#')) {
    title = lines.first.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    lines.removeAt(0);
  }
  return (title, lines.join('\n').trim());
}

String _rowRawJson(Map<String, Object?> row) {
  try {
    return jsonEncode(<String, Object?>{
      for (final MapEntry<String, Object?> e in row.entries)
        e.key: e.value is Uint8ListLike ? null : e.value,
    });
  } catch (_) {
    return '{}';
  }
}

String _fileRawJson(File file) {
  try {
    final content = _readTextSafe(file);
    final payload = <String, Object?>{'file': _fileNameOf(file.path)};
    if (content != null) {
      payload['content'] = content;
      payload['sha256'] = sha256.convert(utf8.encode(content)).toString();
    }
    return jsonEncode(payload);
  } catch (_) {
    return '{}';
  }
}

String? _readTextSafe(File file) {
  try {
    return file.readAsStringSync();
  } catch (_) {
    return null;
  }
}

String _hash16(String text) =>
    sha256.convert(utf8.encode(text)).toString().substring(0, 16);

String _hash12(String text) =>
    sha256.convert(utf8.encode(text)).toString().substring(0, 12);

String _fileNameOf(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}

String _extensionOf(String path) {
  final name = _fileNameOf(path);
  final index = name.lastIndexOf('.');
  return index <= 0 ? '' : name.substring(index + 1);
}

String _stemOf(String name) {
  final index = name.lastIndexOf('.');
  return index <= 0 ? name : name.substring(0, index);
}

String _joinPath(String a, String b) {
  final normalized = a.endsWith('/') || a.endsWith('\\') ? a.substring(0, a.length - 1) : a;
  return '$normalized/$b';
}

int _now() => DateTime.now().millisecondsSinceEpoch;

/// 用该时间的 UTC+8 日期键标注导入会话标题
String _dayKeyOf(int millis) {
  final local = DateTime.fromMillisecondsSinceEpoch(millis + 8 * 3600 * 1000, isUtc: true);
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// 占位类型：区分 BLOB（导入源库暂无 BLOB 列，保留扩展点）
typedef Uint8ListLike = List<int>;
