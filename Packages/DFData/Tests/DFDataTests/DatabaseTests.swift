import XCTest
import DFCore
@testable import DFData

final class DatabaseTests: XCTestCase {
    private var temporaryRoot: URL!
    private var database: AppDatabase!
    private var conversations: GRDBConversationRepository!
    private var messages: GRDBMessageRepository!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DaFeiYuTests-\(UUID().uuidString)", isDirectory: true)
        let paths = DatabasePaths(root: temporaryRoot)
        database = try AppDatabase(paths: paths)
        conversations = GRDBConversationRepository(database: database)
        messages = GRDBMessageRepository(database: database)
    }

    override func tearDownWithError() throws {
        database = nil
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testMigrationCreatesHealthyDatabase() throws {
        let report = try IntegrityChecker(
            database: database,
            attachments: AttachmentStore(root: database.paths.attachmentsRoot)
        ).run()

        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.databaseCheck.lowercased(), "ok")
        XCTAssertEqual(report.schemaVersion, "v2_memory")
        XCTAssertEqual(report.messageCount, 0)
    }

    func testEnsureMainConversationIsIdempotent() async throws {
        let first = try await conversations.ensureMainConversation(title: "大肥鱼")
        let second = try await conversations.ensureMainConversation(title: "大肥鱼")

        XCTAssertEqual(first.id, second.id)
        let all = try await messages.count(in: first.id)
        XCTAssertEqual(all, 0)
    }

    func testInsertAndFetchMessagesInOrder() async throws {
        let conversation = try await conversations.ensureMainConversation(title: "大肥鱼")

        for index in 1...3 {
            let message = Message(
                conversationID: conversation.id,
                role: index % 2 == 0 ? .assistant : .user,
                text: "第\(index)条",
                status: .sent,
                origin: index % 2 == 0 ? .reply : .user,
                createdAt: Int64(index)
            )
            try await messages.insert(message)
        }

        let recent = try await messages.recentMessages(in: conversation.id, limit: 10)
        XCTAssertEqual(recent.map(\.text), ["第1条", "第2条", "第3条"])
    }

    func testRecentMessagesReturnsNewestWindow() async throws {
        let conversation = try await conversations.ensureMainConversation(title: "大肥鱼")
        for index in 1...20 {
            let message = Message(
                conversationID: conversation.id,
                role: .user,
                text: "第\(index)条",
                status: .sent,
                origin: .user,
                createdAt: Int64(index)
            )
            try await messages.insert(message)
        }

        let recent = try await messages.recentMessages(in: conversation.id, limit: 5)
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.first?.text, "第16条")
        XCTAssertEqual(recent.last?.text, "第20条")
    }

    func testDuplicateClientUUIDIsRejected() async throws {
        let conversation = try await conversations.ensureMainConversation(title: "大肥鱼")
        let uuid = UUID().uuidString
        let first = Message(clientUUID: uuid, conversationID: conversation.id, role: .user, text: "你好", origin: .user)
        let duplicate = Message(clientUUID: uuid, conversationID: conversation.id, role: .user, text: "你好", origin: .user)

        try await messages.insert(first)

        do {
            try await messages.insert(duplicate)
            XCTFail("重复的 client_uuid 必须被唯一索引拒绝")
        } catch {
            // 预期：数据库唯一约束错误
        }

        let total = try await messages.count(in: conversation.id)
        XCTAssertEqual(total, 1)
    }

    func testUpdateMessageStatus() async throws {
        let conversation = try await conversations.ensureMainConversation(title: "大肥鱼")
        var message = Message(conversationID: conversation.id, role: .user, text: "你好", status: .sending, origin: .user)
        try await messages.insert(message)

        message = message.markingSent(at: 12345)
        try await messages.update(message)

        let stored = try await messages.message(id: message.id)
        XCTAssertEqual(stored?.status, .sent)
        XCTAssertEqual(stored?.sentAt, 12345)
    }

    func testPersonaIsCreatedOnceAndCorePromptIsReadable() async throws {
        let personas = GRDBPersonaRepository(database: database)
        let first = try await personas.ensureCorePersona(name: "小肥", systemPrompt: "你是鲸鱼娘")
        let second = try await personas.ensureCorePersona(name: "改个名字不应生效", systemPrompt: "不应覆盖")

        XCTAssertEqual(first.id, second.id)
        XCTAssertTrue(first.isLocked)
        let prompt = try await personas.coreSystemPrompt()
        XCTAssertEqual(prompt, "你是鲸鱼娘")
    }

    func testModelConfigDefaultSwitching() async throws {
        let configs = GRDBModelConfigRepository(database: database)
        var first = ModelConfig(name: "主模型", baseURL: "https://example.com/v1", modelID: "m1", isDefault: true)
        let second = ModelConfig(name: "备用", baseURL: "https://example.org/v1", modelID: "m2")
        try await configs.save(first)
        try await configs.save(second)

        try await configs.makeDefault(id: second.id)

        let current = try await configs.defaultConfig()
        XCTAssertEqual(current?.id, second.id)

        first.name = "改名"
        try await configs.save(first)
        let all = try await configs.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first(where: { $0.id == first.id })?.name, "改名")
    }

    func testAttachmentStoreDeduplicates() throws {
        let store = AttachmentStore(root: database.paths.attachmentsRoot)
        let data = Data("fake-image-bytes".utf8)

        let first = try store.store(data: data, fileExtension: "jpg")
        let second = try store.store(data: data, fileExtension: "jpg")

        XCTAssertEqual(first.sha256, second.sha256)
        XCTAssertEqual(first.relativePath, second.relativePath)
        XCTAssertTrue(store.exists(relativePath: first.relativePath))
    }

    func testIntegrityCheckerReportsMissingFile() throws {
        let store = AttachmentStore(root: database.paths.attachmentsRoot)
        let stored = try store.store(data: Data("abc".utf8), fileExtension: "bin")

        try database.dbQueue.write { db in
            let record = AttachmentRecord(
                sha256: stored.sha256,
                kind: "file",
                relPath: stored.relativePath,
                byteSize: stored.byteSize,
                mime: "application/octet-stream"
            )
            try record.insert(db)
        }
        try store.remove(relativePath: stored.relativePath)

        let report = try IntegrityChecker(database: database, attachments: store).run()
        XCTAssertFalse(report.isHealthy)
        XCTAssertEqual(report.missingAttachmentFiles.count, 1)
    }

    func testSettingsRoundTrip() async throws {
        let settings = GRDBSettingsRepository(database: database)
        try await settings.set("true", for: "quiet_hours_enabled")
        let value = try await settings.string(for: "quiet_hours_enabled")
        XCTAssertEqual(value, "true")
        let missing = try await settings.string(for: "missing")
        XCTAssertNil(missing)
    }
}
