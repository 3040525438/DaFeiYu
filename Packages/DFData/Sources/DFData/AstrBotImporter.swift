import Foundation
import GRDB
import DFCore

/// AstrBot 全量导入器（W9 / 决策 38–40）。
///
/// 硬规则：
/// 1. **只读源数据**：先把源文件复制到暂存目录再打开，原件只做 SHA256 前后比对；
/// 2. **只增不覆盖**：不修改任何既有会话/消息/记忆/日记/人格，冲突一律进待处理区；
/// 3. **每行有归属**：每个源行必须落入"新增 / 重复 / 待处理"之一，覆盖校验失败即整批回滚；
/// 4. **可回滚**：`astrbot_id_map` 记录本批次造出的每一个目标 ID，回滚只删这些；
/// 5. **可追溯**：批次、计数、报告、待处理原因、原始 JSON 全部落库。
public struct AstrBotImporter: AstrBotImporting, Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - 预演 / 正式导入

    public func run(
        source: AstrBotSourcePaths,
        options: AstrBotImportOptions
    ) async throws -> AstrBotImportReport {
        guard source.hasAnySource else { throw AstrBotImportError.noSource }

        let startedAt = Clock.nowMillis()
        let prepared: PreparedSources
        do {
            prepared = try Self.prepareSources(source, options: options)
        } catch {
            // 源缺失/不可读也要留痕，避免"失败却没有记录"
            let message = (error as? AstrBotImportError)?.description ?? error.localizedDescription
            let failureBatchID = "astrbot-\(startedAt)-preparefailed"
            try? await database.write { db in
                try Self.recordFailure(
                    db,
                    batchID: failureBatchID,
                    isDryRun: options.isDryRun,
                    sourceRef: "",
                    sourceHash: "",
                    startedAt: startedAt,
                    counts: AstrBotImportCounts(),
                    error: message
                )
            }
            throw GRDBErrorMapper.map(error)
        }
        defer { prepared.cleanUpStaging() }

        let batchID = Self.makeBatchID(at: startedAt, hash: prepared.sourceHash)
        let existingCorePersona = try await database.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM personas WHERE kind = 'core' LIMIT 1")
        }

        let plan: ImportPlan
        do {
            plan = try Self.buildPlan(
                prepared: prepared,
                options: options,
                existingCorePersona: existingCorePersona
            )
        } catch {
            // 映射阶段失败也要留痕：批次表写一条 failed，不写任何业务数据
            let message = (error as? AstrBotImportError)?.description ?? error.localizedDescription
            try? await database.write { db in
                try Self.recordFailure(
                    db,
                    batchID: batchID,
                    isDryRun: options.isDryRun,
                    sourceRef: prepared.sourceRef,
                    sourceHash: prepared.sourceHash,
                    startedAt: startedAt,
                    counts: AstrBotImportCounts(),
                    error: message
                )
            }
            throw GRDBErrorMapper.map(error)
        }

        let outcome = ImportOutcome(counts: plan.counts)
        var failure: Error?

        do {
            try await database.write { db in
                try Self.insertBatch(
                    db,
                    batchID: batchID,
                    status: .running,
                    isDryRun: options.isDryRun,
                    sourceRef: prepared.sourceRef,
                    sourceHash: prepared.sourceHash,
                    startedAt: startedAt,
                    counts: plan.counts,
                    error: nil
                )

                let legacyBefore = try Self.legacyFingerprint(db)
                try Self.apply(plan, batchID: batchID, now: startedAt, db: db, outcome: outcome)
                try Self.verifyPostconditions(db, plan: plan, outcome: outcome, legacyBefore: legacyBefore)

                if options.isDryRun {
                    // 预演：主动抛错回滚整个事务，只保留内存里的计数
                    throw DryRunSignal()
                }

                try Self.updateBatchFinished(
                    db,
                    batchID: batchID,
                    status: .succeeded,
                    finishedAt: Clock.nowMillis(),
                    counts: outcome.counts,
                    error: nil
                )
            }
        } catch is DryRunSignal {
            // 事务已整体回滚，这里单独写一条预演批次记录
            let finishedAt = Clock.nowMillis()
            try await database.write { db in
                try Self.insertBatch(
                    db,
                    batchID: batchID,
                    status: .dryRunSucceeded,
                    isDryRun: true,
                    sourceRef: prepared.sourceRef,
                    sourceHash: prepared.sourceHash,
                    startedAt: startedAt,
                    counts: outcome.counts,
                    error: nil
                )
                try Self.updateBatchFinished(
                    db,
                    batchID: batchID,
                    status: .dryRunSucceeded,
                    finishedAt: finishedAt,
                    counts: outcome.counts,
                    error: nil
                )
            }
        } catch {
            failure = error
        }

        // 原始数据保护：导入前后源文件指纹必须一致
        try prepared.verifyUnchanged()

        if let failure {
            let message = (failure as? AstrBotImportError)?.description ?? failure.localizedDescription
            try? await database.write { db in
                try Self.recordFailure(
                    db,
                    batchID: batchID,
                    isDryRun: options.isDryRun,
                    sourceRef: prepared.sourceRef,
                    sourceHash: prepared.sourceHash,
                    startedAt: startedAt,
                    counts: outcome.counts,
                    error: message
                )
            }
            throw GRDBErrorMapper.map(failure)
        }

        let status: AstrBotImportStatus = options.isDryRun ? .dryRunSucceeded : .succeeded
        return AstrBotImportReport(
            batchID: batchID,
            status: status,
            isDryRun: options.isDryRun,
            sourceHash: prepared.sourceHash,
            startedAt: startedAt,
            finishedAt: Clock.nowMillis(),
            counts: outcome.counts,
            pendingByReason: outcome.pendingByReason
        )
    }

    // MARK: - 回滚

    public func rollback(batchID: String, at millis: Int64) async throws -> AstrBotRollbackReport {
        try await database.write { db in
            guard let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM astrbot_migration_batches WHERE id = ?",
                arguments: [batchID]
            ) else {
                throw AstrBotImportError.invalidBatch(batchID)
            }
            guard status != AstrBotImportStatus.rolledBack.rawValue else {
                throw AstrBotImportError.alreadyRolledBack(batchID)
            }
            guard status != AstrBotImportStatus.running.rawValue else {
                throw AstrBotImportError.rollbackNotAllowed("批次仍在执行中")
            }

            func targetIDs(_ kind: AstrBotEntityKind) throws -> [String] {
                try String.fetchAll(
                    db,
                    sql: "SELECT target_id FROM astrbot_id_map WHERE batch_id = ? AND entity_kind = ?",
                    arguments: [batchID, kind.rawValue]
                )
            }

            let messageIDs = try targetIDs(.message)
            let conversationIDs = try targetIDs(.conversation)
            let memoryIDs = try targetIDs(.memory) + targetIDs(.document)
            let diaryIDs = try targetIDs(.diary)
            let personaItemIDs = try targetIDs(.personaItem)
            let personaIDs = try targetIDs(.persona)

            for id in messageIDs {
                try db.execute(sql: "DELETE FROM message_fts WHERE message_id = ?", arguments: [id])
            }
            for id in memoryIDs {
                try db.execute(sql: "DELETE FROM memory_fts WHERE memory_id = ?", arguments: [id])
            }
            for id in diaryIDs {
                try db.execute(sql: "DELETE FROM diary_fts WHERE diary_id = ?", arguments: [id])
            }

            var deletedMessages = 0
            for id in messageIDs {
                try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [id])
                deletedMessages += db.changesCount
            }
            var deletedConversations = 0
            for id in conversationIDs {
                try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id])
                deletedConversations += db.changesCount
            }
            var deletedMemories = 0
            for id in memoryIDs {
                try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
                deletedMemories += db.changesCount
            }
            var deletedDiaries = 0
            for id in diaryIDs {
                try db.execute(sql: "DELETE FROM diary_entries WHERE id = ?", arguments: [id])
                deletedDiaries += db.changesCount
            }
            var deletedPersonaItems = 0
            for id in personaItemIDs {
                try db.execute(sql: "DELETE FROM persona_items WHERE id = ?", arguments: [id])
                deletedPersonaItems += db.changesCount
            }
            var deletedPersonas = 0
            for id in personaIDs {
                try db.execute(sql: "DELETE FROM personas WHERE id = ?", arguments: [id])
                deletedPersonas += db.changesCount
            }

            let deletedPending = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM astrbot_import_pending WHERE batch_id = ?",
                arguments: [batchID]
            ) ?? 0
            try db.execute(sql: "DELETE FROM astrbot_import_pending WHERE batch_id = ?", arguments: [batchID])

            let deletedIDMaps = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM astrbot_id_map WHERE batch_id = ?",
                arguments: [batchID]
            ) ?? 0
            try db.execute(sql: "DELETE FROM astrbot_id_map WHERE batch_id = ?", arguments: [batchID])

            // 人格导入记录带 batch_id，回滚时一并清掉，避免"已回滚却显示成功"
            try db.execute(
                sql: "DELETE FROM persona_imports WHERE source_kind = 'astrbot' AND report_json LIKE ?",
                arguments: ["%\(batchID)%"]
            )

            try db.execute(
                sql: """
                UPDATE astrbot_migration_batches
                   SET status = ?, finished_at = ?, error = NULL
                 WHERE id = ?
                """,
                arguments: [AstrBotImportStatus.rolledBack.rawValue, millis, batchID]
            )

            return AstrBotRollbackReport(
                batchID: batchID,
                status: .rolledBack,
                deletedMessages: deletedMessages,
                deletedConversations: deletedConversations,
                deletedMemories: deletedMemories,
                deletedDiaries: deletedDiaries,
                deletedPersonaItems: deletedPersonaItems,
                deletedPersonas: deletedPersonas,
                deletedPending: deletedPending,
                deletedIDMaps: deletedIDMaps
            )
        }
    }

    // MARK: - 查询

    public func batches(limit: Int) async throws -> [AstrBotBatchSummary] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, is_dry_run, status, source_ref, source_hash, started_at, finished_at,
                       error, counts_json
                  FROM astrbot_migration_batches
                 ORDER BY started_at DESC
                 LIMIT ?
                """,
                arguments: [max(1, limit)]
            )
            return try rows.map { row in
                AstrBotBatchSummary(
                    id: try row.decode(String.self, forColumn: "id"),
                    isDryRun: (try row.decode(Int.self, forColumn: "is_dry_run")) != 0,
                    status: try row.decode(String.self, forColumn: "status"),
                    sourceRef: try row.decode(String.self, forColumn: "source_ref"),
                    sourceHash: Self.optionalString(row, "source_hash"),
                    startedAt: try row.decode(Int64.self, forColumn: "started_at"),
                    finishedAt: Self.optionalInt64(row, "finished_at"),
                    error: Self.optionalString(row, "error"),
                    counts: Self.decodeCounts((Self.optionalString(row, "counts_json") ?? "{}"))
                )
            }
        }
    }

    public func pendingItems(batchID: String, limit: Int) async throws -> [AstrBotPendingItem] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, batch_id, entity_kind, source_id, reason_code, raw_json, status,
                       resolved_target_id, created_at, resolved_at
                  FROM astrbot_import_pending
                 WHERE batch_id = ?
                 ORDER BY created_at ASC, id ASC
                 LIMIT ?
                """,
                arguments: [batchID, max(1, limit)]
            )
            return rows.map { row in
                AstrBotPendingItem(
                    id: (try? row.decode(String.self, forColumn: "id")) ?? "",
                    batchID: batchID,
                    entityKind: (try? row.decode(String.self, forColumn: "entity_kind")) ?? "",
                    sourceID: Self.optionalString(row, "source_id"),
                    reasonCode: (try? row.decode(String.self, forColumn: "reason_code")) ?? "",
                    rawJSON: (try? row.decode(String.self, forColumn: "raw_json")) ?? "{}",
                    status: (try? row.decode(String.self, forColumn: "status")) ?? "pending",
                    resolvedTargetID: Self.optionalString(row, "resolved_target_id"),
                    createdAt: (try? row.decode(Int64.self, forColumn: "created_at")) ?? 0,
                    resolvedAt: Self.optionalInt64(row, "resolved_at")
                )
            }
        }
    }

    public func resolvePending(id: String, targetID: String?, at millis: Int64) async throws {
        try await database.write { db in
            guard let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM astrbot_import_pending WHERE id = ?",
                arguments: [id]
            ) else {
                throw AstrBotImportError.pendingNotFound(id)
            }
            guard status == "pending" else { return }
            try db.execute(
                sql: """
                UPDATE astrbot_import_pending
                   SET status = 'resolved', resolved_target_id = ?, resolved_at = ?
                 WHERE id = ?
                """,
                arguments: [targetID, millis, id]
            )
        }
    }
}

// MARK: - 内部信号与计数容器

/// 预演回滚信号：只用于跳出事务，不对外暴露。
private struct DryRunSignal: Error {}

/// 事务内的可变结果容器（事务回滚后计数仍需保留给报告）。
private final class ImportOutcome: @unchecked Sendable {
    var counts: AstrBotImportCounts
    var pendingByReason: [String: Int] = [:]
    /// 写入前的存量（重复导入时用于算增量，而不是拿全表数比较）
    var messagesImportedBefore = 0
    var diariesImportedBefore = 0

    init(counts: AstrBotImportCounts) {
        self.counts = counts
    }

    func addPending(_ reason: AstrBotPendingReason) {
        pendingByReason[reason.rawValue, default: 0] += 1
    }
}

// MARK: - 源准备（暂存副本 + 指纹）

private struct PreparedSources {
    var sourceRef: String
    var sourceHash: String
    /// 原件路径与指纹（前后比对用）
    var originalHashes: [String: String]
    var stagingRoot: URL?

    var chatMemoryDatabase: URL?
    var longTermMemoryDatabase: URL?
    var personaDatabase: URL?
    var diaryDirectory: URL?
    var lettersDirectory: URL?
    var bookNotesDirectory: URL?
    var companionLedgerJSON: URL?

    func cleanUpStaging() {
        if let stagingRoot {
            try? FileManager.default.removeItem(at: stagingRoot)
        }
    }

    func verifyUnchanged() throws {
        let manager = FileManager.default
        for (path, expected) in originalHashes {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw AstrBotImportError.sourceMissing(path)
            }
            let current = isDirectory.boolValue
                ? try AstrBotImporter.directoryHash(url)
                : try AstrBotImporter.fileHash(url)
            guard current == expected else {
                throw AstrBotImportError.sourceChanged(path)
            }
        }
    }
}

// MARK: - 映射计划

private struct ImportPlan: Sendable {
    var conversations: [PlannedConversation]
    var messages: [PlannedMessage]
    var memories: [PlannedMemory]
    var diaries: [PlannedDiary]
    var persona: PlannedPersona?
    var documents: [PlannedDocument]
    var pendings: [PlannedPending]
    var counts: AstrBotImportCounts
}

private struct PlannedConversation: Sendable {
    var id: String
    var title: String
    var createdAt: Int64
    var updatedAt: Int64
}

private struct PlannedMessage: Sendable {
    var id: String
    var clientUUID: String
    var conversationID: String
    var role: String
    var kind: String
    var text: String
    var status: String
    var createdAt: Int64
    var sentAt: Int64?
    var replyToID: String?
    var deletedAt: Int64?
    var revokedAt: Int64?
}

private struct PlannedMemory: Sendable {
    var id: String
    var type: String
    var title: String
    var content: String
    var category: String
    var dedupeKey: String
    var sourceID: String
    var createdAt: Int64
}

private struct PlannedDiary: Sendable {
    var id: String
    var entryDate: String
    var title: String
    var content: String
    var createdAt: Int64
}

private struct PlannedPersona: Sendable {
    var id: String
    var name: String
    var sourcePersonaID: String
    var items: [PlannedPersonaItem]
}

private struct PlannedPersonaItem: Sendable {
    var id: String
    var section: String
    var key: String
    var value: String
}

private struct PlannedDocument: Sendable {
    var id: String
    var type: String
    var title: String
    var content: String
    var category: String
    var dedupeKey: String
    var sourceID: String
    var createdAt: Int64
}

private struct PlannedPending: Sendable {
    var id: String
    var entityKind: String
    var sourceID: String?
    var reason: AstrBotPendingReason
    var rawJSON: String
}

// MARK: - 源读取辅助

private struct SourceDateParser {
    private let formatter: DateFormatter
    private let dayFormatter: DateFormatter

    init() {
        let zone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = zone
        dayFormatter.dateFormat = "yyyy-MM-dd"
    }

    /// `2026-10-24 01:47:38.052761` → 毫秒（源库时间按 UTC+8 解释）
    func millis(from text: String?) -> Int64? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let base = formatter.date(from: String(parts[0])) else { return nil }
        var millis = Int64((base.timeIntervalSince1970 * 1000).rounded())
        if parts.count == 2, let fraction = Double("0." + parts[1]) {
            millis += Int64((fraction * 1000).rounded())
        }
        return millis
    }

    /// `yyyy-MM-dd` → 当天 00:00 毫秒；非法日期返回 nil
    func dayMillis(_ day: String) -> Int64? {
        guard GRDBDiaryRepository.isValidDate(day),
              let date = dayFormatter.date(from: day) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - 计划构建

extension AstrBotImporter {
    private static func buildPlan(
        prepared: PreparedSources,
        options: AstrBotImportOptions,
        existingCorePersona: String?
    ) throws -> ImportPlan {
        var plan = ImportPlan(
            conversations: [],
            messages: [],
            memories: [],
            diaries: [],
            persona: nil,
            documents: [],
            pendings: [],
            counts: AstrBotImportCounts()
        )
        let parser = SourceDateParser()

        if let url = prepared.chatMemoryDatabase {
            try readChat(url, options: options, parser: parser, plan: &plan)
        }
        if let url = prepared.longTermMemoryDatabase {
            try readMemories(url, parser: parser, plan: &plan)
        }
        if let url = prepared.personaDatabase {
            try readPersona(url, options: options, existingCorePersona: existingCorePersona, plan: &plan)
        }
        if let url = prepared.diaryDirectory {
            try readDiary(url, parser: parser, plan: &plan)
        }
        if options.importsDocuments {
            if let url = prepared.lettersDirectory {
                try readDocuments(url, category: "letter", type: "letter", plan: &plan)
            }
            if let url = prepared.bookNotesDirectory {
                try readDocuments(url, category: "book_note", type: "book_note", plan: &plan)
            }
        }
        if options.importsRelationshipLedger, let url = prepared.companionLedgerJSON {
            try readCompanionLedger(url, plan: &plan)
        }

        plan.counts.pendingTotal = plan.pendings.count
        let problems = plan.counts.coverageProblems
        if !problems.isEmpty {
            throw AstrBotImportError.coverageMismatch(problems)
        }
        return plan
    }

    // MARK: 聊天

    private static func readChat(
        _ url: URL,
        options: AstrBotImportOptions,
        parser: SourceDateParser,
        plan: inout ImportPlan
    ) throws {
        let queue = try openReadOnly(url)
        defer { try? queue.close() }

        try queue.read { db in
            let tables = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view')"
            )
            guard tables.contains("chat_memory_records") else {
                throw AstrBotImportError.sourceUnreadable(url.path)
            }

            var conversationIndex: [String: Int] = [:]
            var sourceMessageIndex: [String: String] = [:]
            var replyCandidates: [(index: Int, sourceReplyID: String)] = []

            let rows = try Row.fetchAll(db, sql: "SELECT * FROM chat_memory_records ORDER BY id")
            plan.counts.sourceChatRecords = rows.count

            for row in rows {
                let sourceID = int64(row, "id").map { String($0) } ?? ""
                let umo = string(row, "umo") ?? ""
                let conversationKey = string(row, "conversation_id") ?? ""
                let platform = string(row, "platform_name") ?? string(row, "platform_id") ?? "聊天"
                let rawTimestamp: DatabaseValue? = row.hasColumn("raw_timestamp") ? row["raw_timestamp"] : nil
                let createdAt = timestamp(raw: rawTimestamp, text: string(row, "created_at"), parser: parser)
                let role = string(row, "role") ?? ""
                let contentKind = string(row, "content_kind") ?? "[]"
                let content = string(row, "content") ?? ""

                if contentKind.contains("event") {
                    plan.pendings.append(
                        pending(
                            kind: "chat_record",
                            sourceID: sourceID,
                            reason: .systemEvent,
                            rawJSON: rawJSON(row)
                        )
                    )
                    plan.counts.messagesPending += 1
                    continue
                }
                guard role == "user" || role == "assistant" else {
                    plan.pendings.append(
                        pending(kind: "chat_record", sourceID: sourceID, reason: .unknownRole, rawJSON: rawJSON(row))
                    )
                    plan.counts.messagesPending += 1
                    continue
                }
                guard let createdAt else {
                    plan.pendings.append(
                        pending(kind: "chat_record", sourceID: sourceID, reason: .invalidTimestamp, rawJSON: rawJSON(row))
                    )
                    plan.counts.messagesPending += 1
                    continue
                }
                let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    plan.pendings.append(
                        pending(kind: "chat_record", sourceID: sourceID, reason: .emptyContent, rawJSON: rawJSON(row))
                    )
                    plan.counts.messagesPending += 1
                    continue
                }

                let groupKey = umo + "|" + conversationKey
                let conversationID: String
                if let index = conversationIndex[groupKey] {
                    conversationID = plan.conversations[index].id
                    if createdAt > plan.conversations[index].updatedAt {
                        plan.conversations[index].updatedAt = createdAt
                    }
                } else {
                    conversationID = "astrbot-conv-" + String(SHA256.hash(groupKey).prefix(16))
                    conversationIndex[groupKey] = plan.conversations.count
                    plan.conversations.append(
                        PlannedConversation(
                            id: conversationID,
                            title: "\(options.conversationTitlePrefix) · \(platform)",
                            createdAt: createdAt,
                            updatedAt: createdAt
                        )
                    )
                }

                let kind: String
                if contentKind.contains("image") || contentKind.contains("file") {
                    kind = contentKind.contains("image") ? "image" : "mixed"
                    plan.counts.pendingMediaMissing += 1
                    plan.pendings.append(
                        pending(kind: "chat_record", sourceID: sourceID, reason: .mediaMissing, rawJSON: rawJSON(row))
                    )
                } else {
                    kind = "text"
                }

                let localID = "astrbot-msg-\(sourceID)"
                let recalledAt = parser.millis(from: string(row, "recalled_at"))
                let deletedAt = parser.millis(from: string(row, "deleted_at"))

                let message = PlannedMessage(
                    id: localID,
                    clientUUID: "astrbot:chat:\(sourceID)",
                    conversationID: conversationID,
                    role: role,
                    kind: kind,
                    text: text,
                    status: recalledAt == nil ? MessageStatus.sent.rawValue : MessageStatus.recalled.rawValue,
                    createdAt: createdAt,
                    sentAt: createdAt,
                    replyToID: nil,
                    deletedAt: deletedAt,
                    revokedAt: recalledAt
                )
                let messageIndex = plan.messages.count
                plan.messages.append(message)
                plan.counts.messagesNew += 1

                let platformMessageID = string(row, "message_id") ?? ""
                if !platformMessageID.isEmpty {
                    sourceMessageIndex[platformMessageID] = localID
                }
                if let replyID = string(row, "reply_id"), !replyID.isEmpty {
                    replyCandidates.append((messageIndex, replyID))
                }
            }

            // 第二遍：把平台回复 ID 映射成库内消息 ID
            for candidate in replyCandidates {
                if let target = sourceMessageIndex[candidate.sourceReplyID],
                   candidate.index < plan.messages.count {
                    plan.messages[candidate.index].replyToID = target
                } else {
                    plan.counts.pendingReplyTargetMissing += 1
                    plan.pendings.append(
                        PlannedPending(
                            id: UUID().uuidString,
                            entityKind: "chat_record",
                            sourceID: plan.messages[candidate.index].id,
                            reason: .replyTargetMissing,
                            rawJSON: "{\"reply_id\":\"\(candidate.sourceReplyID)\"}"
                        )
                    )
                }
            }

            // 工具记录：保留原始内容，统一进待处理区
            if tables.contains("chat_memory_tool_records") {
                let tools = try Row.fetchAll(db, sql: "SELECT * FROM chat_memory_tool_records ORDER BY id")
                plan.counts.sourceToolRecords = tools.count
                for row in tools {
                    plan.pendings.append(
                        pending(
                            kind: "tool_record",
                            sourceID: int64(row, "id").map { String($0) },
                            reason: .toolRecord,
                            rawJSON: rawJSON(row)
                        )
                    )
                    plan.counts.pendingToolRecords += 1
                }
            }

            // 媒体归档：附件本体已缺失，保留索引元数据
            if tables.contains("chat_memory_media_archive") {
                let media = try Row.fetchAll(db, sql: "SELECT * FROM chat_memory_media_archive ORDER BY created_at")
                plan.counts.sourceMediaArchives = media.count
                for row in media {
                    plan.pendings.append(
                        pending(
                            kind: "media_archive",
                            sourceID: string(row, "media_id"),
                            reason: .mediaArchive,
                            rawJSON: rawJSON(row)
                        )
                    )
                    plan.counts.pendingMediaArchives += 1
                }
            }
        }
    }

    // MARK: 长期记忆

    private static func readMemories(
        _ url: URL,
        parser: SourceDateParser,
        plan: inout ImportPlan
    ) throws {
        let queue = try openReadOnly(url)
        defer { try? queue.close() }

        try queue.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view')")
            guard tables.contains("mem") else {
                throw AstrBotImportError.sourceUnreadable(url.path)
            }

            let rows = try Row.fetchAll(db, sql: "SELECT id, kind, day, text, sig FROM mem ORDER BY id")
            plan.counts.sourceMemories = rows.count

            for row in rows {
                let sourceID = string(row, "sig") ?? int64(row, "id").map { String($0) } ?? ""
                let kind = string(row, "kind") ?? "fact"
                let day = string(row, "day") ?? ""
                let text = string(row, "text") ?? ""

                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    plan.pendings.append(
                        pending(kind: "memory", sourceID: sourceID, reason: .emptyContent, rawJSON: rawJSON(row))
                    )
                    plan.counts.memoriesPending += 1
                    continue
                }
                guard let seenAt = parser.dayMillis(day) else {
                    plan.pendings.append(
                        pending(kind: "memory", sourceID: sourceID, reason: .invalidDay, rawJSON: rawJSON(row))
                    )
                    plan.counts.memoriesPending += 1
                    continue
                }

                let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
                plan.memories.append(
                    PlannedMemory(
                        id: "astrbot-mem-" + String(SHA256.hash("\(sourceID)|\(content)").prefix(16)),
                        type: kind,
                        title: String(content.prefix(40)),
                        content: content,
                        category: kind,
                        dedupeKey: "astrbot:mem:\(sourceID)",
                        sourceID: sourceID,
                        createdAt: seenAt
                    )
                )
                plan.counts.memoriesNew += 1
            }
        }
    }

    // MARK: 人格

    private static func readPersona(
        _ url: URL,
        options: AstrBotImportOptions,
        existingCorePersona: String?,
        plan: inout ImportPlan
    ) throws {
        let queue = try openReadOnly(url)
        defer { try? queue.close() }

        try queue.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view')")
            guard tables.contains("personas") else {
                throw AstrBotImportError.sourceUnreadable(url.path)
            }

            let rows = try Row.fetchAll(db, sql: "SELECT * FROM personas ORDER BY id")
            plan.counts.sourcePersonaRows = rows.count
            guard !rows.isEmpty else { return }

            // 已有核心人格：一律不覆盖，全部进待处理区
            if existingCorePersona != nil {
                for row in rows {
                    plan.pendings.append(
                        pending(
                            kind: "persona",
                            sourceID: string(row, "persona_id"),
                            reason: .personaConflict,
                            rawJSON: rawJSON(row)
                        )
                    )
                    plan.counts.personaPending += 1
                }
                return
            }

            let first = rows[0]
            let sourcePersonaID = string(first, "persona_id") ?? "astrbot"
            let systemPrompt = string(first, "system_prompt") ?? ""
            guard !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                for row in rows {
                    plan.pendings.append(
                        pending(
                            kind: "persona",
                            sourceID: string(row, "persona_id"),
                            reason: .emptyContent,
                            rawJSON: rawJSON(row)
                        )
                    )
                    plan.counts.personaPending += 1
                }
                return
            }

            let personaID = "astrbot-persona-" + String(SHA256.hash(sourcePersonaID).prefix(12))
            var items: [PlannedPersonaItem] = [
                PlannedPersonaItem(
                    id: "astrbot-persona-item-" + String(SHA256.hash("\(sourcePersonaID)|system_prompt").prefix(12)),
                    section: "核心",
                    key: "system_prompt",
                    value: systemPrompt
                )
            ]
            if let dialogs = string(first, "begin_dialogs"),
               dialogs.trimmingCharacters(in: .whitespacesAndNewlines) != "[]" {
                items.append(
                    PlannedPersonaItem(
                        id: "astrbot-persona-item-" + String(SHA256.hash("\(sourcePersonaID)|begin_dialogs").prefix(12)),
                        section: "示例对话",
                        key: "begin_dialogs",
                        value: dialogs
                    )
                )
            }

            plan.persona = PlannedPersona(
                id: personaID,
                name: options.personaName,
                sourcePersonaID: sourcePersonaID,
                items: items
            )
            plan.counts.personaRowsImported += 1
            plan.counts.personaItemsNew += items.count

            for row in rows.dropFirst() {
                plan.pendings.append(
                    pending(
                        kind: "persona",
                        sourceID: string(row, "persona_id"),
                        reason: .personaConflict,
                        rawJSON: rawJSON(row)
                    )
                )
                plan.counts.personaPending += 1
            }
        }
    }

    // MARK: 日记

    private static func readDiary(
        _ url: URL,
        parser: SourceDateParser,
        plan: inout ImportPlan
    ) throws {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AstrBotImportError.sourceUnreadable(url.path)
        }

        let all = files
            .filter { ["md", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        plan.counts.sourceDiaryFiles = all.count

        // `txt/` 子目录是 md 的纯文本镜像：显式计入并跳过，不静默忽略
        let mirrorDirectory = url.appendingPathComponent("txt", isDirectory: true)
        if let mirrors = try? manager.contentsOfDirectory(
            at: mirrorDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let textMirrors = mirrors.filter { $0.pathExtension.lowercased() == "txt" }
            plan.counts.sourceDiaryFiles += textMirrors.count
            plan.counts.diaryMirrors += textMirrors.count
        }

        var importedDates = Set<String>()

        for file in all {
            let name = file.lastPathComponent
            let isMirror = file.pathExtension.lowercased() == "txt"
            let baseName = (name as NSString).deletingPathExtension

            guard GRDBDiaryRepository.isValidDate(baseName) else {
                plan.pendings.append(
                    pending(
                        kind: "diary_file",
                        sourceID: name,
                        reason: .unrecognizedDiaryFile,
                        rawJSON: fileRawJSON(file, content: try? String(contentsOf: file, encoding: .utf8))
                    )
                )
                plan.counts.diaryPending += 1
                continue
            }

            // `txt/` 目录是 md 的镜像，不重复入库，但必须显式计数
            if isMirror {
                plan.counts.diaryMirrors += 1
                continue
            }

            guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
                plan.pendings.append(
                    pending(kind: "diary_file", sourceID: name, reason: .emptyContent, rawJSON: fileRawJSON(file, content: nil))
                )
                plan.counts.diaryPending += 1
                continue
            }

            let parsed = splitDiary(raw)
            guard !parsed.content.isEmpty else {
                plan.pendings.append(
                    pending(kind: "diary_file", sourceID: name, reason: .emptyContent, rawJSON: fileRawJSON(file, content: raw))
                )
                plan.counts.diaryPending += 1
                continue
            }
            guard !importedDates.contains(baseName) else {
                plan.pendings.append(
                    pending(kind: "diary_file", sourceID: name, reason: .diaryDateConflict, rawJSON: fileRawJSON(file, content: raw))
                )
                plan.counts.diaryPending += 1
                continue
            }
            importedDates.insert(baseName)

            plan.diaries.append(
                PlannedDiary(
                    id: "astrbot-diary-\(baseName)",
                    entryDate: baseName,
                    title: parsed.title,
                    content: parsed.content,
                    createdAt: parser.dayMillis(baseName) ?? 0
                )
            )
            plan.counts.diariesNew += 1
        }
    }

    /// 首行 `# 标题` 作标题，其余为正文
    private static func splitDiary(_ raw: String) -> (title: String, content: String) {
        let normalized = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        var lines = normalized.components(separatedBy: .newlines)
        var title = ""
        if let first = lines.first, first.hasPrefix("#") {
            title = String(first.drop(while: { $0 == "#" || $0 == " " }))
                .trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        let content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, content)
    }

    // MARK: 信件与读书笔记

    private static func readDocuments(
        _ url: URL,
        category: String,
        type: String,
        plan: inout ImportPlan
    ) throws {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AstrBotImportError.sourceUnreadable(url.path)
        }

        let docs = files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        plan.counts.sourceDocuments += docs.count

        for file in docs {
            let name = file.lastPathComponent
            guard let raw = try? String(contentsOf: file, encoding: .utf8),
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                plan.pendings.append(
                    pending(kind: category, sourceID: name, reason: .emptyContent, rawJSON: fileRawJSON(file, content: nil))
                )
                plan.counts.documentsPending += 1
                continue
            }
            let parsed = splitDiary(raw)
            let content = parsed.content.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : parsed.content
            plan.documents.append(
                PlannedDocument(
                    id: "astrbot-doc-" + String(SHA256.hash("\(category)|\(name)|\(content)").prefix(16)),
                    type: type,
                    title: parsed.title.isEmpty ? (name as NSString).deletingPathExtension : parsed.title,
                    content: content,
                    category: category,
                    dedupeKey: "astrbot:doc:\(category):\(SHA256.hash("\(name)|\(content)").prefix(16))",
                    sourceID: "\(category):\(name)",
                    createdAt: 0
                )
            )
            plan.counts.documentsNew += 1
        }
    }

    // MARK: 关系账本

    private static func readCompanionLedger(_ url: URL, plan: inout ImportPlan) throws {
        guard let data = try? Data(contentsOf: url) else {
            throw AstrBotImportError.sourceUnreadable(url.path)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let users = root["users"] as? [String: Any] else {
            throw AstrBotImportError.sourceUnreadable(url.path)
        }

        plan.counts.sourceLedgerUsers = users.count
        for identity in users.keys.sorted() {
            let payload = users[identity] ?? [:]
            let raw = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            plan.pendings.append(
                PlannedPending(
                    id: UUID().uuidString,
                    entityKind: "relationship_ledger",
                    sourceID: identity,
                    reason: .relationshipLedger,
                    rawJSON: raw
                )
            )
            plan.counts.ledgerPending += 1
        }
    }

    // MARK: 小工具

    private static func pending(
        kind: String,
        sourceID: String?,
        reason: AstrBotPendingReason,
        rawJSON: String
    ) -> PlannedPending {
        PlannedPending(
            id: UUID().uuidString,
            entityKind: kind,
            sourceID: sourceID,
            reason: reason,
            rawJSON: rawJSON
        )
    }

    private static func fileRawJSON(_ url: URL, content: String?) -> String {
        var dict: [String: Any] = ["file": url.lastPathComponent]
        if let content {
            dict["content"] = content
            dict["sha256"] = SHA256.hash(content)
        }
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func rawJSON(_ row: Row) -> String {
        var dict: [String: Any] = [:]
        for column in row.columnNames {
            guard let convertible = row[column] else {
                dict[column] = NSNull()
                continue
            }
            let value = convertible.databaseValue
            switch value.storage {
            case .null:
                dict[column] = NSNull()
            case .int64(let number):
                dict[column] = number
            case .double(let real):
                dict[column] = real
            case .string(let text):
                dict[column] = text
            case .blob(let data):
                dict[column] = data.base64EncodedString()
            }
        }
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func string(_ row: Row, _ column: String) -> String? {
        guard row.hasColumn(column) else { return nil }
        return String.fromDatabaseValue(row[column])
    }

    private static func int64(_ row: Row, _ column: String) -> Int64? {
        guard row.hasColumn(column) else { return nil }
        return Int64.fromDatabaseValue(row[column])
    }

    /// 可空文本列（避开 `Row.decodeIfPresent` 解析到 Decodable 重载的坑）
    private static func optionalString(_ row: Row, _ column: String) -> String? {
        guard row.hasColumn(column) else { return nil }
        return String.fromDatabaseValue(row[column])
    }

    private static func optionalInt64(_ row: Row, _ column: String) -> Int64? {
        guard row.hasColumn(column) else { return nil }
        return Int64.fromDatabaseValue(row[column])
    }

    private static func timestamp(
        raw: DatabaseValue?,
        text: String?,
        parser: SourceDateParser
    ) -> Int64? {
        if let raw {
            if let seconds = Double.fromDatabaseValue(raw), seconds > 0 {
                return Int64((seconds * 1000).rounded())
            }
        }
        return parser.millis(from: text)
    }
}

// MARK: - 事务内写入

extension AstrBotImporter {
    private static func apply(
        _ plan: ImportPlan,
        batchID: String,
        now: Int64,
        db: Database,
        outcome: ImportOutcome
    ) throws {
        outcome.messagesImportedBefore = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM messages WHERE client_uuid LIKE 'astrbot:chat:%'"
        ) ?? 0
        outcome.diariesImportedBefore = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM diary_entries WHERE id LIKE 'astrbot-diary-%'"
        ) ?? 0

        // 会话
        for conversation in plan.conversations {
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM conversations WHERE id = ?",
                arguments: [conversation.id]
            ) ?? 0
            guard exists == 0 else { continue }
            try db.execute(
                sql: """
                INSERT INTO conversations (id, title, kind, created_at, updated_at)
                VALUES (?, ?, 'imported', ?, ?)
                """,
                arguments: [conversation.id, conversation.title, conversation.createdAt, conversation.updatedAt]
            )
            try map(db, batchID: batchID, kind: .conversation, sourceID: conversation.id, targetID: conversation.id, at: now)
        }

        // 消息
        for message in plan.messages {
            if try String.fetchOne(
                db,
                sql: "SELECT id FROM messages WHERE client_uuid = ?",
                arguments: [message.clientUUID]
            ) != nil {
                outcome.counts.messagesNew -= 1
                outcome.counts.messagesDuplicate += 1
                // 重复行不写 id_map：回滚只能删"本批次造出来的行"，绝不能删既有消息
                continue
            }
            try db.execute(
                sql: """
                INSERT INTO messages
                    (id, client_uuid, conversation_id, role, kind, text, status, origin,
                     reply_to_id, created_at, sent_at, deleted_at, revoked_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'imported', ?, ?, ?, ?, ?)
                """,
                arguments: [
                    message.id, message.clientUUID, message.conversationID, message.role, message.kind,
                    message.text, message.status, message.replyToID, message.createdAt, message.sentAt,
                    message.deletedAt, message.revokedAt
                ]
            )
            try MessageIndexer.index(
                db: db,
                messageID: message.id,
                conversationID: message.conversationID,
                text: message.text
            )
            try map(db, batchID: batchID, kind: .message, sourceID: message.id, targetID: message.id, at: now)
        }

        // 记忆
        let memoryCountBefore = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM memories WHERE dedupe_key LIKE 'astrbot:%'"
        ) ?? 0
        for memory in plan.memories {
            if try String.fetchOne(
                db,
                sql: "SELECT id FROM memories WHERE scope = 'shared' AND dedupe_key = ? AND deleted_at IS NULL",
                arguments: [memory.dedupeKey]
            ) != nil {
                outcome.counts.memoriesNew -= 1
                outcome.counts.memoriesDuplicate += 1
                continue
            }
            try insertMemory(
                db: db,
                id: memory.id,
                type: memory.type,
                title: memory.title,
                content: memory.content,
                category: memory.category,
                dedupeKey: memory.dedupeKey,
                sourceID: memory.sourceID,
                createdAt: memory.createdAt,
                batchID: batchID,
                now: now
            )
            try map(db, batchID: batchID, kind: .memory, sourceID: memory.sourceID, targetID: memory.id, at: now)
        }
        let memoryCountAfter = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM memories WHERE dedupe_key LIKE 'astrbot:%'"
        ) ?? 0
        guard memoryCountAfter - memoryCountBefore == outcome.counts.memoriesNew else {
            throw AstrBotImportError.coverageMismatch([
                "记忆写入数不符：期望 \(outcome.counts.memoriesNew)，实际 \(memoryCountAfter - memoryCountBefore)"
            ])
        }

        // 文档（信件 / 读书笔记）
        for document in plan.documents {
            if try String.fetchOne(
                db,
                sql: "SELECT id FROM memories WHERE scope = 'shared' AND dedupe_key = ? AND deleted_at IS NULL",
                arguments: [document.dedupeKey]
            ) != nil {
                outcome.counts.documentsNew -= 1
                outcome.counts.documentsDuplicate += 1
                continue
            }
            try insertMemory(
                db: db,
                id: document.id,
                type: document.type,
                title: document.title,
                content: document.content,
                category: document.category,
                dedupeKey: document.dedupeKey,
                sourceID: document.sourceID,
                createdAt: document.createdAt == 0 ? now : document.createdAt,
                batchID: batchID,
                now: now
            )
            try map(db, batchID: batchID, kind: .document, sourceID: document.sourceID, targetID: document.id, at: now)
        }

        // 日记
        for diary in plan.diaries {
            if try String.fetchOne(
                db,
                sql: "SELECT id FROM diary_entries WHERE entry_date = ? AND deleted_at IS NULL",
                arguments: [diary.entryDate]
            ) != nil {
                outcome.counts.diariesNew -= 1
                outcome.counts.diaryDuplicates += 1
                continue
            }
            let at = diary.createdAt == 0 ? now : diary.createdAt
            try db.execute(
                sql: """
                INSERT INTO diary_entries
                    (id, entry_date, title, content, source, generated_by, is_user_edited, created_at, updated_at)
                VALUES (?, ?, ?, ?, 'migrated', 'astrbot', 0, ?, ?)
                """,
                arguments: [diary.id, diary.entryDate, diary.title, diary.content, at, at]
            )
            try db.execute(
                sql: """
                INSERT INTO diary_entry_versions
                    (id, diary_id, version, title, content, change_reason, changed_by, created_at)
                VALUES (?, ?, 1, ?, ?, 'AstrBot 迁移导入', 'migration', ?)
                """,
                arguments: [UUID().uuidString, diary.id, diary.title, diary.content, at]
            )
            try db.execute(
                sql: "INSERT INTO diary_fts (diary_id, text_bigram) VALUES (?, ?)",
                arguments: [diary.id, V2Memory.bigram(diary.title + "\n" + diary.content)]
            )
            try map(db, batchID: batchID, kind: .diary, sourceID: diary.entryDate, targetID: diary.id, at: now)
        }

        // 人格
        if let persona = plan.persona {
            try db.execute(
                sql: """
                INSERT INTO personas
                    (id, kind, name, is_locked, current_version, created_at, updated_at, fingerprint_scope, growth_enabled)
                VALUES (?, 'core', ?, 1, 1, ?, ?, 'core', 0)
                """,
                arguments: [persona.id, persona.name, now, now]
            )
            for item in persona.items {
                try db.execute(
                    sql: """
                    INSERT INTO persona_items
                        (id, persona_id, section, key, value, confidence, weight, source, updated_at,
                         tier, tier_status, tier_source, tier_evidence, status)
                    VALUES (?, ?, ?, ?, ?, 1.0, 1.0, 'astrbot', ?, 'core', 'core', 'astrbot_import', ?, 'active')
                    """,
                    arguments: [
                        item.id, persona.id, item.section, item.key, item.value, now,
                        "{\"source\":\"astrbot\",\"persona\":\"\(persona.sourcePersonaID)\"}"
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO persona_item_tier_history
                        (id, item_id, from_tier, to_tier, from_status, to_status, reason, evidence_json,
                         decided_by, created_at)
                    VALUES (?, ?, NULL, 'core', NULL, 'core', 'astrbot_import', '{}', 'migration', ?)
                    """,
                    arguments: [UUID().uuidString, item.id, now]
                )
                try map(db, batchID: batchID, kind: .personaItem, sourceID: item.key, targetID: item.id, at: now)
            }
            let snapshot = personaSnapshot(name: persona.name, items: persona.items)
            try db.execute(
                sql: """
                INSERT INTO persona_versions
                    (id, persona_id, version, snapshot_json, change_reason, changed_by, created_at)
                VALUES (?, ?, 1, ?, 'AstrBot 迁移导入', 'migration', ?)
                """,
                arguments: [UUID().uuidString, persona.id, snapshot, now]
            )
            let fingerprint = SHA256.hash(snapshot)
            try db.execute(
                sql: "UPDATE personas SET fingerprint = ?, fingerprint_at = ? WHERE id = ?",
                arguments: [fingerprint, now, persona.id]
            )
            try db.execute(
                sql: "INSERT INTO persona_fingerprints (id, persona_id, scope, fingerprint, item_count, computed_at, trigger, status) VALUES (?, ?, 'core', ?, ?, ?, 'astrbot_import', 'baseline')",
                arguments: [UUID().uuidString, persona.id, fingerprint, persona.items.count, now]
            )
            try db.execute(
                sql: """
                INSERT INTO persona_imports
                    (id, source_kind, source_name, source_ref, source_hash, item_total, item_imported,
                     item_skipped, status, report_json, started_at, finished_at)
                VALUES (?, 'astrbot', 'AstrBot 人格', ?, NULL, ?, ?, 0, 'succeeded', ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString, persona.sourcePersonaID, persona.items.count, persona.items.count,
                    "{\"batch_id\":\"\(batchID)\"}", now, now
                ]
            )
            try map(db, batchID: batchID, kind: .persona, sourceID: persona.sourcePersonaID, targetID: persona.id, at: now)
        }

        // 待处理区
        for item in plan.pendings {
            try db.execute(
                sql: """
                INSERT INTO astrbot_import_pending
                    (id, batch_id, entity_kind, source_id, reason_code, raw_json, status, created_at)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
                """,
                arguments: [item.id, batchID, item.entityKind, item.sourceID, item.reason.rawValue, item.rawJSON, now]
            )
            outcome.addPending(item.reason)
        }
    }

    private static func insertMemory(
        db: Database,
        id: String,
        type: String,
        title: String,
        content: String,
        category: String,
        dedupeKey: String,
        sourceID: String,
        createdAt: Int64,
        batchID: String,
        now: Int64
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO memories
                (id, type, title, content, importance, salience, confidence, status, first_seen_at,
                 scope, layer, category, source_kind, epistemic_status, version, dedupe_key, heat,
                 classification_status, created_at, updated_at, importance_score, importance_source,
                 importance_source_at, original_external_id, original_content, original_created_at,
                 import_batch_id, classification_evidence_json)
            VALUES (?, ?, ?, ?, 'normal', 0.5, 0.5, 'active', ?,
                    'shared', 'semantic', ?, 'astrbot_import', 'observed', 1, ?, 'warm',
                    'pending', ?, ?, 0.5, 'legacy_text', ?, ?, ?, ?, ?, '[]')
            """,
            arguments: [
                id, type, title, content, createdAt, category, dedupeKey,
                createdAt, createdAt, now, sourceID, content, createdAt, batchID
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO memory_versions
                (id, memory_id, version, title, content, change_reason, changed_by, source_kind, created_at)
            VALUES (?, ?, 1, ?, ?, 'AstrBot 迁移导入', 'migration', 'astrbot_import', ?)
            """,
            arguments: [UUID().uuidString, id, title, content, createdAt]
        )
        try db.execute(
            sql: """
            INSERT INTO memory_sources (id, memory_id, source_type, source_id, excerpt, at, created_at)
            VALUES (?, ?, 'astrbot_memory', ?, ?, ?, ?)
            """,
            arguments: [UUID().uuidString, id, sourceID, String(content.prefix(200)), createdAt, createdAt]
        )
        try db.execute(
            sql: "INSERT INTO memory_fts (memory_id, scope, text_bigram) VALUES (?, 'shared', ?)",
            arguments: [id, V2Memory.bigram(title + " " + content)]
        )
    }

    private static func map(
        _ db: Database,
        batchID: String,
        kind: AstrBotEntityKind,
        sourceID: String,
        targetID: String,
        at millis: Int64
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO astrbot_id_map (id, batch_id, entity_kind, source_id, target_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [UUID().uuidString, batchID, kind.rawValue, sourceID, targetID, millis]
        )
    }

    private static func personaSnapshot(name: String, items: [PlannedPersonaItem]) -> String {
        let payload: [String: Any] = [
            "name": name,
            "items": items.map { ["section": $0.section, "key": $0.key, "value": $0.value] }
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - 校验

extension AstrBotImporter {
    private static func verifyPostconditions(
        _ db: Database,
        plan: ImportPlan,
        outcome: ImportOutcome,
        legacyBefore: String
    ) throws {
        let problems = outcome.counts.coverageProblems
        if !problems.isEmpty {
            throw AstrBotImportError.coverageMismatch(problems)
        }

        let messageCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") ?? 0
        let importedMessages = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM messages WHERE client_uuid LIKE 'astrbot:chat:%'"
        ) ?? 0
        guard importedMessages - outcome.messagesImportedBefore == outcome.counts.messagesNew else {
            throw AstrBotImportError.coverageMismatch([
                "消息写入数不符：期望 \(outcome.counts.messagesNew)，实际 \(importedMessages - outcome.messagesImportedBefore)"
            ])
        }
        guard messageCount >= importedMessages else {
            throw AstrBotImportError.coverageMismatch(["消息总数异常：\(messageCount)"])
        }

        let diaryCount = try Int.fetchOne(db, sql: "SELECT count(*) FROM diary_entries") ?? 0
        let importedDiaries = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM diary_entries WHERE id LIKE 'astrbot-diary-%'"
        ) ?? 0
        guard importedDiaries - outcome.diariesImportedBefore == outcome.counts.diariesNew,
              diaryCount >= importedDiaries else {
            throw AstrBotImportError.coverageMismatch(["日记写入数不符：\(importedDiaries)"])
        }

        let legacyAfter = try legacyFingerprint(db)
        guard legacyAfter == legacyBefore else {
            throw AstrBotImportError.coverageMismatch(["既有数据内容指纹发生变化（导入只增不覆盖）"])
        }

        let quick = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quick.lowercased() == "ok" else {
            throw AstrBotImportError.coverageMismatch(["quick_check 失败：\(quick)"])
        }
    }

    /// 只覆盖"非本导入器写入"的行，用于证明导入没有改动既有数据。
    private static func legacyFingerprint(_ db: Database) throws -> String {
        var buffer = ""
        buffer += try legacyLines(db, sql: """
        SELECT quote(id) || '|' || quote(title) || '|' || quote(kind) || '|' || quote(coalesce(archived_at, -1))
          FROM conversations WHERE id NOT LIKE 'astrbot-%' ORDER BY id
        """)
        buffer += try legacyLines(db, sql: """
        SELECT quote(id) || '|' || quote(text) || '|' || quote(status) || '|' || quote(kind)
               || '|' || quote(coalesce(deleted_at, -1)) || '|' || quote(coalesce(revoked_at, -1))
          FROM messages WHERE id NOT LIKE 'astrbot-%' ORDER BY id
        """)
        buffer += try legacyLines(db, sql: """
        SELECT quote(id) || '|' || quote(content) || '|' || quote(scope) || '|' || quote(status)
          FROM memories WHERE id NOT LIKE 'astrbot-%' ORDER BY id
        """)
        buffer += try legacyLines(db, sql: """
        SELECT quote(id) || '|' || quote(content) || '|' || quote(entry_date)
          FROM diary_entries WHERE id NOT LIKE 'astrbot-diary-%' ORDER BY id
        """)
        buffer += try legacyLines(db, sql: """
        SELECT quote(id) || '|' || quote(value) FROM persona_items
         WHERE persona_id NOT LIKE 'astrbot-%' ORDER BY id
        """)
        return SHA256.hash(buffer)
    }

    private static func legacyLines(_ db: Database, sql: String) throws -> String {
        let lines = try String.fetchAll(db, sql: sql)
        return lines.joined(separator: "\u{1E}") + "\u{1F}"
    }
}

// MARK: - 批次读写

extension AstrBotImporter {
    private static func insertBatch(
        _ db: Database,
        batchID: String,
        status: AstrBotImportStatus,
        isDryRun: Bool,
        sourceRef: String,
        sourceHash: String,
        startedAt: Int64,
        counts: AstrBotImportCounts,
        error: String?
    ) throws {
        let countsJSON = encodeCounts(counts)
        try db.execute(
            sql: """
            INSERT INTO astrbot_migration_batches
                (id, source_kind, source_ref, source_hash, is_dry_run, status, options_json,
                 counts_json, checkpoint_json, started_at, finished_at, error)
            VALUES (?, 'astrbot', ?, ?, ?, ?, '{}', ?, '{}', ?, NULL, ?)
            """,
            arguments: [batchID, sourceRef, sourceHash, isDryRun ? 1 : 0, status.rawValue, countsJSON, startedAt, error]
        )
    }

    private static func updateBatchFinished(
        _ db: Database,
        batchID: String,
        status: AstrBotImportStatus,
        finishedAt: Int64,
        counts: AstrBotImportCounts,
        error: String?
    ) throws {
        try db.execute(
            sql: """
            UPDATE astrbot_migration_batches
               SET status = ?, finished_at = ?, counts_json = ?, error = ?
             WHERE id = ?
            """,
            arguments: [status.rawValue, finishedAt, encodeCounts(counts), error, batchID]
        )
    }

    /// 失败留痕：已有批次就改成 failed，没有才新建，避免主键冲突丢记录。
    private static func recordFailure(
        _ db: Database,
        batchID: String,
        isDryRun: Bool,
        sourceRef: String,
        sourceHash: String,
        startedAt: Int64,
        counts: AstrBotImportCounts,
        error: String
    ) throws {
        let finishedAt = Clock.nowMillis()
        try db.execute(
            sql: """
            UPDATE astrbot_migration_batches
               SET status = ?, finished_at = ?, counts_json = ?, error = ?
             WHERE id = ?
            """,
            arguments: [AstrBotImportStatus.failed.rawValue, finishedAt, encodeCounts(counts), error, batchID]
        )
        guard db.changesCount == 0 else { return }
        try insertBatch(
            db,
            batchID: batchID,
            status: .failed,
            isDryRun: isDryRun,
            sourceRef: sourceRef,
            sourceHash: sourceHash,
            startedAt: startedAt,
            counts: counts,
            error: error
        )
        try updateBatchFinished(
            db,
            batchID: batchID,
            status: .failed,
            finishedAt: finishedAt,
            counts: counts,
            error: error
        )
    }

    private static func encodeCounts(_ counts: AstrBotImportCounts) -> String {
        (try? JSONEncoder().encode(counts)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func decodeCounts(_ json: String) -> AstrBotImportCounts {
        guard let data = json.data(using: .utf8),
              let counts = try? JSONDecoder().decode(AstrBotImportCounts.self, from: data) else {
            return AstrBotImportCounts()
        }
        return counts
    }
}

// MARK: - 源准备与只读打开

extension AstrBotImporter {
    private static func prepareSources(
        _ source: AstrBotSourcePaths,
        options: AstrBotImportOptions
    ) throws -> PreparedSources {
        let manager = FileManager.default
        let stagingRoot = (options.stagingDirectory
            ?? manager.temporaryDirectory.appendingPathComponent("astrbot-import-\(UUID().uuidString)", isDirectory: true))
        try manager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        var succeeded = false
        defer {
            if !succeeded {
                try? manager.removeItem(at: stagingRoot)
            }
        }

        var originalHashes: [String: String] = [:]
        var staged = PreparedSources(
            sourceRef: "",
            sourceHash: "",
            originalHashes: [:],
            stagingRoot: stagingRoot,
            chatMemoryDatabase: nil,
            longTermMemoryDatabase: nil,
            personaDatabase: nil,
            diaryDirectory: nil,
            lettersDirectory: nil,
            bookNotesDirectory: nil,
            companionLedgerJSON: nil
        )

        func stage(_ url: URL?) throws -> URL? {
            guard let url else { return nil }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw AstrBotImportError.sourceMissing(url.path)
            }
            let hash: String
            if isDirectory.boolValue {
                hash = try directoryHash(url)
            } else {
                hash = try fileHash(url)
            }
            originalHashes[url.path] = hash
            if !isDirectory.boolValue, url.pathExtension.lowercased() == "db" {
                for suffix in ["-wal", "-shm"] {
                    let sidecar = URL(fileURLWithPath: url.path + suffix)
                    if manager.fileExists(atPath: sidecar.path) {
                        originalHashes[sidecar.path] = try fileHash(sidecar)
                    }
                }
            }
            let destination = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: isDirectory.boolValue)
            do {
                try manager.copyItem(at: url, to: destination)
                // WAL 库：连同 -wal/-shm 一起复制，避免丢掉未 checkpoint 的事务
                if !isDirectory.boolValue, url.pathExtension.lowercased() == "db" {
                    for suffix in ["-wal", "-shm"] {
                        let sidecar = URL(fileURLWithPath: url.path + suffix)
                        guard manager.fileExists(atPath: sidecar.path) else { continue }
                        try manager.copyItem(
                            at: sidecar,
                            to: URL(fileURLWithPath: destination.path + suffix)
                        )
                    }
                }
            } catch {
                throw AstrBotImportError.sourceUnreadable(url.path)
            }
            return destination
        }

        staged.chatMemoryDatabase = try stage(source.chatMemoryDatabase)
        staged.longTermMemoryDatabase = try stage(source.longTermMemoryDatabase)
        staged.personaDatabase = try stage(source.personaDatabase)
        staged.diaryDirectory = try stage(source.diaryDirectory)
        staged.lettersDirectory = try stage(source.lettersDirectory)
        staged.bookNotesDirectory = try stage(source.bookNotesDirectory)
        staged.companionLedgerJSON = try stage(source.companionLedgerJSON)

        let combined = originalHashes
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "\n")

        staged.originalHashes = originalHashes
        staged.sourceHash = SHA256.hash(combined)
        staged.sourceRef = source.chatMemoryDatabase?.lastPathComponent
            ?? source.longTermMemoryDatabase?.lastPathComponent
            ?? source.personaDatabase?.lastPathComponent
            ?? "astrbot"
        succeeded = true
        return staged
    }

    static func fileHash(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw AstrBotImportError.sourceUnreadable(url.path)
        }
        return SHA256.hash(data)
    }

    static func directoryHash(_ url: URL) throws -> String {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AstrBotImportError.sourceUnreadable(url.path)
        }
        var entries: [String] = []
        while let file = enumerator.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let relative = file.path.replacingOccurrences(of: url.path, with: "")
            entries.append(relative + ":" + ((try? fileHash(file)) ?? ""))
        }
        return SHA256.hash(entries.sorted().joined(separator: "\n"))
    }

    static func openReadOnly(_ url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        do {
            return try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            throw AstrBotImportError.sourceUnreadable(url.path)
        }
    }

    static func makeBatchID(at millis: Int64, hash: String) -> String {
        "astrbot-\(millis)-" + String(hash.prefix(8))
    }
}
