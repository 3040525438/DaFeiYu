import Foundation
import Combine
import DFCore
import DFData
import DFAI
import DFOrchestration

/// 日记补偿结果（界面与后台任务共用，不暴露数据层类型）
struct DiaryCompensationSummary: Sendable, Equatable {
    var generated = 0
    var skipped = 0
    var failedNotes: [String] = []

    var isEmpty: Bool {
        generated == 0 && skipped == 0 && failedNotes.isEmpty
    }
}

/// 待确认记忆提案的界面投影（不把数据层类型暴露给 UI）
struct MemoryProposalSummary: Identifiable, Sendable, Equatable {
    var id: String
    var title: String
    var content: String
    var evidenceQuote: String
    var scope: String
    var risk: String
    var reason: String
    var createdAt: Int64
}

/// 依赖装配：整个应用只在这里创建具体实现。
/// 刻意不加 @MainActor：它是纯依赖容器，不含 UI 状态；
/// 这样各层都能安全引用，UI 状态仍由 @MainActor 的 ViewModel 管理。
final class AppContainer: ObservableObject {
    let environment: AppEnvironment
    let database: AppDatabase
    let attachments: AttachmentStore
    let secureStore: KeychainStore

    let conversations: ConversationRepository
    let messages: MessageRepository
    let personas: PersonaRepository
    let modelConfigs: ModelConfigRepository
    let settings: SettingsRepository
    let integrityChecker: IntegrityChecker
    /// W2：编辑留痕 / 撤回 / 收藏
    let editing: MessageEditingRepository
    /// W2：四类删除
    let deletion: MessageDeletionRepository
    /// W2：会话内搜索
    let chatSearch: ChatSearchRepository
    /// W2：主题与气泡个性化
    let chatTheme: ChatThemeStoring
    /// W3：多会话管理（建 / 改名 / 置顶 / 归档 / 排序 / 未读 / 删除保留记忆）
    let conversationAdmin: ConversationAdminRepository
    /// W4：附件元数据 / OCR 与转写文本 / 多图分析
    let attachmentRecords: AttachmentRepository
    let attachmentTexts: AttachmentTextRepository
    let imageAnalyses: ImageAnalysisRepository
    /// W4：附件入库与设备端派生处理
    let media: AttachmentIngestService
    /// W5：本地模型注册与事件
    let localModels: LocalModelRepository
    /// W6：每日日记
    let diary: DiaryRepository
    /// W6 / D34：每日日记自动生成与补偿（真实聊天 + 严格 JSON）
    let diaryAuto: DiaryAutoService
    /// W8：记忆（三主体 + 版本 + 按来源删除）
    let memories: MemoryRepository
    /// W9：备份清单与恢复日志
    let backups: BackupRepository
    /// D10：预算与成本（真实成本统计 + 并发安全预占）
    let budget: BudgetService
    /// D25：跨域统一检索（聊天 / 记忆 / 日记 / 附件）
    let unifiedSearch: UnifiedSearchRepository
    /// D26：消息整理（收藏 / 重要 / 标签 / 批量）
    let messageOrganization: MessageOrganizationRepository
    /// D57：附件引用检查与清理
    let attachmentReferences: AttachmentReferenceService
    /// D36：当前启用角色（无角色时补建内置角色）
    let characters: CharacterProfileService
    /// D36 / D37：角色状态读写（表情、精力、亲和与历史）
    let characterStates: CharacterStateService
    /// D73：表情包（内置 Emoji / 本地导入 / 在线下载 / 收藏 / 最近使用）
    let stickers: StickerRepository

    // MARK: - W6~W9 服务层

    /// W7：自主调度（策略 / 任务队列 / 闸门 / 补算）
    let autonomy: AutonomyService
    /// W7：主动消息治理
    let proactive: ProactiveMessageService
    /// N-20：主动意图生成（严格 JSON）与过闸门投递
    let intents: ProactiveIntentService
    /// N-20：把"用户久未说话"变成可执行的主动任务
    let proactiveScheduler: ProactiveScheduler
    /// D47：AI 主动创建会话（同主题复用、去重、间隔与日上限）
    let proactiveConversations: ProactiveConversationService
    /// W6：人格成长（提案 → 审批 → 版本回退）
    let personaGrowth: PersonaGrowthService
    /// D06：人格文件导入（只生成待审批提案）
    let personaImport: PersonaFileImportService
    /// W6：关系档案与阶段确认
    let relationships: RelationshipService
    /// W8：L1–L7 记忆加工
    let memoryProcessing: MemoryProcessingService
    /// W9：备份加解密与恢复
    let backupService: BackupService
    /// D09：自动备份调度（每日完整 + 数据变更增量）
    let backupScheduler: BackupScheduleService
    /// W9：隐私门禁与删除清单
    let privacy: PrivacyGateService
    /// W9：AstrBot 全量导入
    let astrbotImporter: AstrBotImporter
    /// W9：备份密钥（Keychain）
    let backupKeys: KeychainBackupKeyStore
    /// N-08：主动消息系统通知
    let notifications = ProactiveNotificationService()

    /// 全局活跃轮次登记表（L2）：跨页面 / 恢复路径共享。
    let activeTurns = ActiveTurnRegistry()

    /// 会话级协调器缓存（L2）。每个 `conversationID` 唯一，容器持有，页面生命周期不影响。
    /// 仅由 `@MainActor` 入口访问，因此无需额外加锁。
    private var coordinators: [String: ConversationCoordinator] = [:]

    /// 编排层仓储。`groups` 用具体类型：它同时实现 `StaleTurnRecoveryRepository`，
    /// 恢复入口需要这个能力（协议类型会丢掉该 conformance）。
    let groups: GRDBMessageGroupRepository

    let turns: GRDBMessageTurnRepository
    let references: GRDBMessageReferenceRepository
    let contextUnits: GRDBContextUnitProvider

    init(identity: EnvironmentIdentity) throws {
        self.environment = identity.environment

        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent(identity.environment.dataDirectoryName, isDirectory: true)
        let paths = DatabasePaths(root: root)

        // 四重一致性：环境声明、目录名、库路径归属、Keychain service。
        // 任一不符即抛错，不建库、不写任何文件。
        try identity.validate(
            root: root,
            databaseURL: paths.databaseURL,
            keychainService: identity.environment.keychainService
        )

        // 目录归属标记：空目录写入；标记不符、缺失但已有数据、或文件损坏一律拒绝启动。
        try EnvironmentMarkerStore.verifyOrCreate(
            root: root,
            expected: identity.environment,
            createdBy: AppBuildInfo.current,
            now: Clock.nowMillis()
        )

        let database = try AppDatabase(paths: paths)
        let attachments = AttachmentStore(root: database.paths.attachmentsRoot)

        self.database = database
        self.attachments = attachments
        self.secureStore = KeychainStore(service: identity.environment.keychainService)

        self.conversations = GRDBConversationRepository(database: database)
        self.messages = GRDBMessageRepository(database: database)
        self.personas = GRDBPersonaRepository(database: database)
        self.modelConfigs = GRDBModelConfigRepository(database: database)
        self.settings = GRDBSettingsRepository(database: database)
        self.integrityChecker = IntegrityChecker(database: database, attachments: attachments)
        self.editing = GRDBMessageEditingRepository(database: database)
        self.deletion = GRDBMessageDeletionRepository(database: database)
        self.chatSearch = GRDBChatSearchRepository(database: database)
        self.chatTheme = GRDBChatThemeStore(settings: GRDBSettingsRepository(database: database))
        self.conversationAdmin = GRDBConversationAdminRepository(database: database)
        self.attachmentRecords = GRDBAttachmentRepository(database: database)
        self.attachmentTexts = GRDBAttachmentTextRepository(database: database)
        self.imageAnalyses = GRDBImageAnalysisRepository(database: database)
        self.media = AttachmentIngestService(
            store: attachments,
            repository: GRDBAttachmentRepository(database: database),
            textRepository: GRDBAttachmentTextRepository(database: database)
        )
        self.localModels = GRDBLocalModelRepository(database: database)
        self.diary = GRDBDiaryRepository(database: database)
        self.memories = GRDBMemoryRepository(database: database)
        self.backups = GRDBBackupRepository(database: database)
        self.unifiedSearch = GRDBUnifiedSearchRepository(database: database)
        self.messageOrganization = GRDBMessageOrganizationRepository(database: database)
        self.attachmentReferences = GRDBAttachmentReferenceService(database: database)
        self.characters = CharacterProfileService(database: database)
        self.characterStates = CharacterStateService(database: database)
        self.stickers = GRDBStickerRepository(database: database)
        self.budget = BudgetService(
            database: database,
            settings: GRDBSettingsRepository(database: database)
        )

        let autonomyService = AutonomyService(database: database)
        let proactiveService = ProactiveMessageService(database: database)
        self.autonomy = autonomyService
        self.proactive = proactiveService
        self.intents = ProactiveIntentService(
            database: database,
            autonomy: autonomyService,
            proactive: proactiveService
        )
        self.proactiveScheduler = ProactiveScheduler(
            database: database,
            autonomy: autonomyService
        )
        self.proactiveConversations = ProactiveConversationService(
            database: database,
            conversations: GRDBConversationAdminRepository(database: database),
            autonomy: autonomyService
        )
        let personaGrowthService = PersonaGrowthService(database: database)
        self.personaGrowth = personaGrowthService
        self.personaImport = PersonaFileImportService(
            database: database,
            personas: GRDBPersonaRepository(database: database),
            growth: personaGrowthService
        )
        self.relationships = RelationshipService(database: database)
        self.memoryProcessing = MemoryProcessingService(database: database)
        self.privacy = PrivacyGateService(database: database)
        self.astrbotImporter = AstrBotImporter(database: database)
        // 日记自动生成：真实聊天 → 严格 JSON → diary_entries，可选沉淀为长期记忆
        self.diaryAuto = DiaryAutoService(
            database: database,
            diary: GRDBDiaryRepository(database: database),
            distiller: DiaryMemoryService(
                diary: GRDBDiaryRepository(database: database),
                processing: MemoryProcessingService(database: database)
            )
        )

        let backupKeys = KeychainBackupKeyStore(store: KeychainStore(service: identity.environment.keychainService))
        self.backupKeys = backupKeys
        let backupService = BackupService(
            database: database,
            keyStore: backupKeys,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        )
        self.backupService = backupService
        self.backupScheduler = BackupScheduleService(
            database: database,
            settings: GRDBSettingsRepository(database: database)
        ) { kind, note in
            try await backupService.createBackup(kind: kind, note: note)
        }

        self.groups = GRDBMessageGroupRepository(database: database)
        self.turns = GRDBMessageTurnRepository(database: database)
        self.references = GRDBMessageReferenceRepository(database: database)
        self.contextUnits = GRDBContextUnitProvider(database: database)
    }

    var dataRootPath: String {
        database.paths.root.path
    }

    /// 诊断包与存储分类（W10-3）
    var diagnostics: DiagnosticsService {
        DiagnosticsService(
            database: database,
            integrity: integrityChecker,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        )
    }

    /// D59：用户数据导出（隐私页入口）
    var userDataExporter: UserDataExporter {
        UserDataExporter(database: database)
    }

    /// 本地模型文件目录（W5 / D58）
    var localModelsDirectory: URL {
        let directory = database.paths.workspace.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// D61：本地模型独立备份（只复制用户勾选的模型文件）
    var localModelBackupService: LocalModelBackupService {
        LocalModelBackupService(database: database)
    }

    /// 本地模型下载器（W5 / D58–D61）：断点续传 + 校验和 + 仅 Wi-Fi。
    func makeLocalModelDownloader() -> LocalModelDownloader {
        LocalModelDownloader(
            repository: localModels,
            fetcher: URLSessionLocalModelFetcher(),
            network: WiFiOnlyNetworkGate(),
            rootDirectory: localModelsDirectory
        )
    }

    var schemaVersion: String {
        database.currentSchemaVersion
    }

    /// 首次启动确保存在核心人格。幂等，不会覆盖已有设定。
    func bootstrap() async {
        do {
            _ = try await personas.ensureCorePersona(
                name: "大肥鱼",
                systemPrompt: Self.placeholderCorePrompt
            )
        } catch {
            NSLog("初始化核心人格失败：\(error.localizedDescription)")
        }
    }

    /// D73：内置表情入库（幂等）。离线可用，不依赖网络；不覆盖用户已有表情。
    func bootstrapStickers() async {
        do {
            let pack = try await stickers.ensurePack(
                name: BuiltInStickerCatalog.packName,
                source: .builtin,
                sourceURL: nil,
                license: nil
            )
            let now = Clock.nowMillis()
            for entry in BuiltInStickerCatalog.entries {
                _ = try await stickers.insert(
                    NewSticker(
                        packID: pack.id,
                        kind: .emoji,
                        name: entry.name,
                        tags: entry.tags,
                        emoji: entry.emoji,
                        semantics: entry.semantics,
                        semanticsSource: .catalog
                    ),
                    at: now
                )
            }
        } catch {
            NSLog("内置表情初始化失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 每日日记自动生成（W6 / D34）

    /// 用当日真实聊天生成日记。未配置云端模型时抛 `notConfigured`，不写任何数据。
    func generateDiary(dayKey: String) async throws -> DiaryAutoService.Report {
        let config = try await Self.requireDefaultConfig(modelConfigs)
        let provider = try Self.makeProvider(config: config, secureStore: secureStore)
        let persona = ((try? await personas.coreSystemPrompt()) ?? nil) ?? ""
        return try await diaryAuto.generate(
            dayKey: dayKey,
            timeZoneIdentifier: LocalDay.resolvedTimeZoneIdentifier(nil),
            provider: provider,
            model: config.modelID,
            persona: persona,
            distill: true
        )
    }

    /// 补偿：把"23:00 已过但还没有日记"的日子补上。已有日记（含手写）的日期不处理。
    ///
    /// 返回给界面与后台任务用的**纯计数摘要**，避免 UI 层直接依赖数据层类型。
    @discardableResult
    func runDiaryCompensation(
        lookbackDays: Int = DiarySchedulePolicy.defaultLookbackDays
    ) async -> DiaryCompensationSummary {
        let reports = await diaryAuto.runCompensation(lookbackDays: lookbackDays) { day in
            try await generateDiary(dayKey: day)
        }
        var summary = DiaryCompensationSummary()
        for report in reports {
            switch report.status {
            case .generated, .updated:
                summary.generated += 1
            case .skippedNoContent, .skippedUserEdited:
                summary.skipped += 1
            case .failed:
                summary.failedNotes.append(report.note)
            }
        }
        return summary
    }

    // MARK: - 记忆管理（D12 / W8）

    /// 待用户确认的记忆提案（重要度高的抽取结果不会直接生效）
    func pendingMemoryProposals(limit: Int = 50) async -> [MemoryProposalSummary] {
        let items = (try? await memoryProcessing.pendingProposals(limit: limit)) ?? []
        return items.map { item in
            MemoryProposalSummary(
                id: item.id,
                title: item.title,
                content: item.content,
                evidenceQuote: item.evidenceQuote,
                scope: item.scope.rawValue,
                risk: item.risk,
                reason: item.reason,
                createdAt: item.createdAt
            )
        }
    }

    /// 用户确认：真正写入长期记忆
    func approveMemoryProposal(id: String) async throws {
        _ = try await memoryProcessing.approveProposal(id: id, at: Clock.nowMillis())
    }

    func rejectMemoryProposal(id: String, note: String = "用户驳回") async throws {
        try await memoryProcessing.rejectProposal(id: id, note: note, at: Clock.nowMillis())
    }

    func apiKey(for config: ModelConfig) throws -> String {
        guard let key = try secureStore.get(config.keyRef), !key.isEmpty else {
            throw DFError.notConfigured("模型密钥（\(config.name)）")
        }
        return key
    }

    func provider(for config: ModelConfig) throws -> ChatModelProvider {
        guard let url = URL(string: config.baseURL), url.scheme?.hasPrefix("http") == true else {
            throw DFError.invalidURL(config.baseURL)
        }
        return OpenAICompatibleProvider(
            baseURL: url,
            apiKey: try apiKey(for: config),
            modelID: config.modelID
        )
    }

    /// 取得（或创建）某会话的唯一协调器（L2）。
    ///
    /// 生成所有权从页面转移到容器：同一 `conversationID` 恒返回同一协调器，
    /// 页面切 Tab / 离开 / 重建都不会中断正在进行的轮次。
    @MainActor
    func conversationCoordinator(for conversationID: String) -> ConversationCoordinator {
        if let existing = coordinators[conversationID] {
            return existing
        }
        let ownerToken = UUID()
        let orchestrator = ChatOrchestratorImpl(
            dependencies: makeOrchestratorDependencies(conversationID: conversationID),
            pageToken: ownerToken
        )
        let coordinator = ConversationCoordinator(
            conversationID: conversationID,
            orchestrator: orchestrator,
            ownerToken: ownerToken,
            registry: activeTurns
        )
        coordinators[conversationID] = coordinator
        return coordinator
    }

    /// 构造编排器依赖（S5-A）。
    ///
    /// 编排器实例一律由 `conversationCoordinator(for:)` 创建并交由协调器持有；
    /// 页面不再创建编排器，也不持有任何 owner token。
    ///
    /// 闭包只捕获 Sendable 的仓储/存储值，不捕获 `self`，避免把非 Sendable 的容器带进并发域。
    func makeOrchestratorDependencies(conversationID: String? = nil) -> ChatOrchestratorDependencies {
        let modelConfigs = self.modelConfigs
        let personas = self.personas
        let secureStore = self.secureStore
        let budgetService = self.budget
        // D36 / D37：角色与状态（闭包只捕获服务值，不捕获容器）
        let charactersService = self.characters
        let statesService = self.characterStates
        // 记忆召回兜底：泛问句时补日记 / 高显著度记忆 / 跨会话历史
        let recall = RecallContextBuilder(database: self.database, memories: self.memories, diary: self.diary)
        // 回合后置：记忆抽取（W8-3）。关掉开关即完全跳过，不影响聊天。
        let extraction = MemoryExtractionCoordinator(
            processing: memoryProcessing,
            makeRequest: { systemPrompt, userMessage in
                let config = try await Self.requireDefaultConfig(modelConfigs)
                return ChatRequest(
                    model: config.modelID,
                    systemPrompt: systemPrompt,
                    messages: [ChatTurn(role: .user, text: userMessage)],
                    temperature: 0.2,
                    maxTokens: 700
                )
            },
            makeProvider: {
                let config = try await Self.requireDefaultConfig(modelConfigs)
                return try Self.makeProvider(config: config, secureStore: secureStore)
            },
            isEnabled: { [settings] in
                let value = try? await settings.string(for: "memory.extraction.enabled")
                return value != "false"
            }
        )

        return ChatOrchestratorDependencies(
            groups: groups,
            turns: turns,
            messages: messages,
            references: references,
            units: contextUnits,
            recovery: groups,
            makeProvider: {
                let config = try await Self.requireDefaultConfig(modelConfigs)
                return try Self.makeProvider(config: config, secureStore: secureStore)
            },
            makeRequest: { systemPrompt, history in
                let config = try await Self.requireDefaultConfig(modelConfigs)
                return ChatRequest(
                    model: config.modelID,
                    systemPrompt: systemPrompt,
                    messages: history.isEmpty
                        ? [ChatTurn(role: .user, text: "（继续）")]
                        : history,
                    temperature: 0.85
                )
            },
            corePersona: {
                (try await personas.coreSystemPrompt()) ?? ""
            },
            // D37：当前情绪来自角色状态；没有状态数据时返回 nil，只用静态表达准则
            currentEmotion: {
                guard let id = try? await charactersService.activeCharacterID(),
                      let state = try? await statesService.state(for: id) else { return nil }
                return EmotionState(kind: EmotionKind(mood: state.mood), intensity: 0.5)
            },
            // L3：注入本地时间，模型自身没有系统时钟
            currentStateText: { Self.localStateText() },
            // L4：先按本轮输入检索；命中为空或问句在问过去时，兜底补日记 / 重要记忆 / 跨会话历史
            retrieveMemories: { query, limit in
                await recall.recall(
                    query: query,
                    currentConversationID: conversationID,
                    now: Clock.nowMillis(),
                    limit: max(limit, 12)
                )
            },
            rules: PromptComposer.defaultRules,
            limitGroups: 20,
            budget: PromptBudget(totalTokens: 6000),
            onTurnCompleted: { completion in
                await extraction.handle(completion)
                // D37：一轮结束后推断情绪并落库，下一轮提示词与界面都会跟着变
                await Self.recordEmotion(
                    completion: completion,
                    characters: charactersService,
                    states: statesService
                )
            },
            reserveBudget: { request in
                let config = try await Self.requireDefaultConfig(modelConfigs)
                return try await Self.reserveChatBudget(
                    budgetService,
                    request: request,
                    provider: config.providerKind
                )
            },
            settleBudget: { reservationID, usage, request, outputText in
                await Self.settleChatBudget(
                    budgetService,
                    reservationID: reservationID,
                    usage: usage,
                    request: request,
                    outputText: outputText
                )
            }
        )
    }

    // MARK: - D10 聊天预算接线

    /// L3 当前状态文本：模型没有系统时钟，必须显式告诉它"现在几点、星期几、今天/昨天是哪天"。
    static func localStateText(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        CurrentTimeContext.describe(now: now, timeZone: timeZone)
    }

    /// 聊天请求前预占：有单价按"输入估算 + 最大输出"预估，无单价时预估为 0（结算记为无法计量）。
    private static func reserveChatBudget(
        _ budget: BudgetService,
        request: ChatRequest,
        provider: String
    ) async throws -> String? {
        let pricing = try await budget.pricing(modelID: request.model)
        let promptTokens = TokenEstimator.estimate(
            system: request.systemPrompt,
            turns: request.messages
        )
        let estimate = pricing.map {
            $0.estimatedCost(
                promptTokens: promptTokens,
                maxCompletionTokens: request.maxTokens ?? 1024
            )
        } ?? 0
        return try await budget.reserve(
            scope: .chat,
            estimatedYuan: estimate,
            provider: provider,
            modelID: request.model
        )
    }

    /// 请求结束统一结算：用量齐全即 confirmed；缺用量按输出文本估算；缺单价记 unavailable。
    private static func settleChatBudget(
        _ budget: BudgetService,
        reservationID: String?,
        usage: Usage?,
        request: ChatRequest,
        outputText: String
    ) async {
        guard let reservationID else { return }
        do {
            let pricing = try await budget.pricing(modelID: request.model)
            try await budget.settle(
                reservationID: reservationID,
                usage: usage,
                pricing: pricing,
                fallbackPromptTokens: TokenEstimator.estimate(
                    system: request.systemPrompt,
                    turns: request.messages
                ),
                fallbackCompletionTokens: TokenEstimator.estimate(outputText),
                modelID: request.model
            )
        } catch {
            // 结算失败不回滚聊天结果，但必须留下可排查记录
            NSLog("聊天成本结算失败（预占 \(reservationID)）：\(error.localizedDescription)")
        }
    }

    /// D37：一轮结束后推断情绪并写入角色状态。
    ///
    /// 失败只记录日志：情绪是体验性数据，不能因为它回滚聊天结果。
    private static func recordEmotion(
        completion: ChatTurnCompletion,
        characters: CharacterProfileService,
        states: CharacterStateService
    ) async {
        do {
            let characterID = try await characters.activeCharacterID()
            let current = try await states.state(for: characterID)
            let previous = EmotionState(kind: EmotionKind(mood: current.mood), intensity: 0.5)
            let inferred = EmotionSignal.infer(
                userText: completion.userText,
                assistantText: completion.assistantText,
                previous: previous
            )
            try await states.update(
                characterID: characterID,
                emotion: inferred,
                source: "chat",
                triggerMessageID: completion.assistantMessageID
            )
        } catch {
            NSLog("情绪状态更新失败：\(error.localizedDescription)")
        }
    }

    /// 取默认模型配置，缺失时给出与旧链路一致的错误文案。
    private static func requireDefaultConfig(
        _ modelConfigs: ModelConfigRepository
    ) async throws -> ModelConfig {
        guard let config = try await modelConfigs.defaultConfig() else {
            throw DFError.notConfigured("默认模型（请到设置页添加）")
        }
        return config
    }

    private static func makeProvider(
        config: ModelConfig,
        secureStore: KeychainStore
    ) throws -> ChatModelProvider {
        guard let url = URL(string: config.baseURL), url.scheme?.hasPrefix("http") == true else {
            throw DFError.invalidURL(config.baseURL)
        }
        guard let key = try secureStore.get(config.keyRef), !key.isEmpty else {
            throw DFError.notConfigured("模型密钥（\(config.name)）")
        }
        return OpenAICompatibleProvider(baseURL: url, apiKey: key, modelID: config.modelID)
    }

    /// 阶段一占位人格。阶段二会以 AstrBot 的真实设定建立新版本，而不是覆盖历史。
    static let placeholderCorePrompt = """
    你是「大肥鱼」，也被叫作「小肥」或「泡泡」。
    你与用户是长期相处的关系，不是一次性问答，也不是通用助手。
    保持人格连续性：语气、习惯、偏好应稳定；不要自称 AI，也不要假装记得没有记录的事。
    （这是第一阶段的占位核心人格，真正的设定将在 AstrBot 迁移阶段导入。）
    """
}
