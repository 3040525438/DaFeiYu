import Foundation
import Combine
import DFCore
import DFData
import DFAI

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

    init(environment: AppEnvironment) throws {
        self.environment = environment

        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent(environment.dataDirectoryName, isDirectory: true)

        let database = try AppDatabase(paths: DatabasePaths(root: root))
        let attachments = AttachmentStore(root: database.paths.attachmentsRoot)

        self.database = database
        self.attachments = attachments
        self.secureStore = KeychainStore(service: environment.keychainService)

        self.conversations = GRDBConversationRepository(database: database)
        self.messages = GRDBMessageRepository(database: database)
        self.personas = GRDBPersonaRepository(database: database)
        self.modelConfigs = GRDBModelConfigRepository(database: database)
        self.settings = GRDBSettingsRepository(database: database)
        self.integrityChecker = IntegrityChecker(database: database, attachments: attachments)
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

    /// 阶段一占位人格。阶段二会以 AstrBot 的真实设定建立新版本，而不是覆盖历史。
    static let placeholderCorePrompt = """
    你是「大肥鱼」，也被叫作「小肥」或「泡泡」。
    你与用户是长期相处的关系，不是一次性问答，也不是通用助手。
    保持人格连续性：语气、习惯、偏好应稳定；不要自称 AI，也不要假装记得没有记录的事。
    （这是第一阶段的占位核心人格，真正的设定将在 AstrBot 迁移阶段导入。）
    """
}
