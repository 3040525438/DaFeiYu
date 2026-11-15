import XCTest
import GRDB
import DFCore
@testable import DFData

/// D36：角色状态读写——默认态、夹取、幂等、历史留痕与情绪映射。
final class CharacterStateServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: CharacterStateService!
    private var clock = ClockBox()

    private final class ClockBox: @unchecked Sendable {
        var value: Int64 = 1_000
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFCharacterState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        clock = ClockBox()
        service = CharacterStateService(database: database, now: { [box = clock] in
            box?.value ?? 0
        })
    }

    override func tearDownWithError() throws {
        service = nil
        database = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func insertCharacter(id: String = "ch1") async throws {
        try await database.write { db in
            try db.execute(sql: """
            INSERT INTO characters (id, name, kind, summary, is_active, sort, created_at, updated_at)
            VALUES (?, '大肥鱼', 'builtin', '', 1, 0, 1000, 1000)
            """, arguments: [id])
        }
    }

    private func historyCount() async throws -> Int {
        try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM character_state_history") ?? 0
        }
    }

    // MARK: - 默认态

    func testCreatesNeutralDefaultStateWithoutHistory() async throws {
        try await insertCharacter()
        let state = try await service.state(for: "ch1")

        XCTAssertEqual(state.mood, .neutral)
        XCTAssertEqual(state.energy, 0.5)
        XCTAssertEqual(state.affinity, 0.5)
        XCTAssertEqual(state.source, "system")
        let historyAfter = try await historyCount()
        XCTAssertEqual(historyAfter, 0, "创建默认态不是变更，不应写历史")
    }

    func testStateIsStableAcrossCalls() async throws {
        try await insertCharacter()
        let first = try await service.state(for: "ch1")
        clock.value = 2_000
        let second = try await service.state(for: "ch1")
        XCTAssertEqual(first, second)
    }

    func testUnknownCharacterThrows() async {
        do {
            _ = try await service.state(for: "missing")
            XCTFail("不存在的角色应报错")
        } catch {
            XCTAssertEqual(error as? CharacterStateService.StateError, .characterNotFound("missing"))
        }
    }

    // MARK: - 更新与历史

    func testUpdatePersistsAndWritesHistory() async throws {
        try await insertCharacter()
        _ = try await service.state(for: "ch1")
        clock.value = 3_000

        let updated = try await service.update(
            characterID: "ch1",
            mood: .joyful,
            energy: 0.8,
            affinity: 0.7,
            source: "chat",
            reason: "聊到旅行"
        )
        XCTAssertEqual(updated.mood, .joyful)
        XCTAssertEqual(updated.energy, 0.8)
        XCTAssertEqual(updated.updatedAt, 3_000)

        let history = try await service.history(for: "ch1")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].fromMood, .neutral)
        XCTAssertEqual(history[0].toMood, .joyful)
        XCTAssertEqual(history[0].fromEnergy, 0.5)
        XCTAssertEqual(history[0].toEnergy, 0.8)
        XCTAssertEqual(history[0].reason, "聊到旅行")
    }

    func testRepeatedIdenticalUpdateIsIdempotent() async throws {
        try await insertCharacter()
        _ = try await service.update(
            characterID: "ch1", mood: .warm, energy: 0.6, affinity: 0.6, reason: "第一次"
        )
        let before = try await historyCount()
        clock.value = 4_000
        _ = try await service.update(
            characterID: "ch1", mood: .warm, energy: 0.6, affinity: 0.6, reason: "第二次"
        )
        let after = try await historyCount()
        XCTAssertEqual(after, before, "状态未变化不应新增历史")
    }

    func testEnergyChangeAloneWritesHistory() async throws {
        try await insertCharacter()
        _ = try await service.update(
            characterID: "ch1", mood: .neutral, energy: 0.6, affinity: 0.5, reason: "精力下降"
        )
        let history = try await service.history(for: "ch1")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].fromMood, history[0].toMood)
        XCTAssertEqual(history[0].toEnergy, 0.6)
    }

    func testOutOfRangeValuesAreClamped() async throws {
        try await insertCharacter()
        let state = try await service.update(
            characterID: "ch1", mood: .excited, energy: 3, affinity: -1, reason: "越界"
        )
        XCTAssertEqual(state.energy, 1)
        XCTAssertEqual(state.affinity, 0)
    }

    func testEmptyReasonIsRejected() async throws {
        try await insertCharacter()
        do {
            _ = try await service.update(
                characterID: "ch1", mood: .sad, energy: 0.4, affinity: 0.5, reason: "   "
            )
            XCTFail("空原因应被拒绝")
        } catch {
            XCTAssertEqual(error as? CharacterStateService.StateError, .emptyReason)
        }
        let historyAfter = try await historyCount()
        XCTAssertEqual(historyAfter, 0)
    }

    func testHistoryIsNewestFirstAndLimited() async throws {
        try await insertCharacter()
        let moods: [CharacterMood] = [.warm, .joyful, .calm, .sad]
        for (index, mood) in moods.enumerated() {
            clock.value = 5_000 + Int64(index)
            _ = try await service.update(
                characterID: "ch1", mood: mood, energy: 0.5, affinity: 0.5, reason: "第\(index)次"
            )
        }
        let limited = try await service.history(for: "ch1", limit: 2)
        XCTAssertEqual(limited.count, 2)
        XCTAssertEqual(limited[0].toMood, .sad, "最新的在前")
        XCTAssertEqual(limited[1].toMood, .calm)
    }

    // MARK: - 情绪映射

    func testUpdateFromEmotionUsesReasonAndKeepsNumbers() async throws {
        try await insertCharacter()
        let state = try await service.update(
            characterID: "ch1",
            emotion: EmotionState(kind: .annoyed, intensity: 0.7, reason: "被打断")
        )
        XCTAssertEqual(state.mood, .annoyed)
        XCTAssertEqual(state.energy, 0.5, "未指定精力时应保留原值")
        XCTAssertEqual(state.source, "chat")

        let history = try await service.history(for: "ch1")
        XCTAssertEqual(history.first?.reason, "被打断")
    }

    func testPresentationIsDerivedFromStoredState() async throws {
        try await insertCharacter()
        let state = try await service.update(
            characterID: "ch1", mood: .excited, energy: 0.9, affinity: 0.9, reason: "见到你"
        )
        let presentation = state.presentation()
        XCTAssertEqual(presentation.mood, .excited)
        XCTAssertEqual(presentation.action, .wave)
        XCTAssertTrue(presentation.animation.isAnimated)

        let still = state.presentation(reduceMotion: true)
        XCTAssertFalse(still.animation.isAnimated)
    }

    func testStateRowIsSinglePerCharacter() async throws {
        try await insertCharacter()
        _ = try await service.update(
            characterID: "ch1", mood: .calm, energy: 0.5, affinity: 0.5, reason: "冷静"
        )
        _ = try await service.update(
            characterID: "ch1", mood: .warm, energy: 0.6, affinity: 0.6, reason: "变温和"
        )
        let rows = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM character_states WHERE character_id = 'ch1'") ?? 0
        }
        XCTAssertEqual(rows, 1, "每个角色只能有一行状态")
    }
}
