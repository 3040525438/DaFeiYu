import Foundation
import Combine
import DFCore
import DFData
import DFAI
import DFOrchestration

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

        self.groups = GRDBMessageGroupRepository(database: database)
        self.turns = GRDBMessageTurnRepository(database: database)
        self.references = GRDBMessageReferenceRepository(database: database)
        self.contextUnits = GRDBContextUnitProvider(database: database)
    }

    var dataRootPath: String {
        database.paths.root.path
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
            dependencies: makeOrchestratorDependencies(),
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
    func makeOrchestratorDependencies() -> ChatOrchestratorDependencies {
        let modelConfigs = self.modelConfigs
        let personas = self.personas
        let secureStore = self.secureStore

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
            rules: PromptComposer.defaultRules,
            limitGroups: 20,
            budget: PromptBudget(totalTokens: 6000)
        )
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
