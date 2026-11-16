import XCTest
import DFCore
@testable import DFData

/// 表情包仓储：写入校验、去重、收藏、最近使用、搜索与软删。
final class StickerRepositoryTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var repository: GRDBStickerRepository!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DFSticker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase(paths: DatabasePaths(root: root))
        repository = GRDBStickerRepository(database: database)
    }

    override func tearDownWithError() throws {
        repository = nil
        database = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func seedAttachment(id: String, sha: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO attachments (id, sha256, kind, rel_path, byte_size, mime, created_at)
                VALUES (?, ?, 'image', ?, 10, 'image/png', 1)
                """,
                arguments: [id, sha, "aa/bb/\(sha).png"]
            )
        }
    }

    func testInsertEmojiRequiresEmojiCharacter() async throws {
        do {
            _ = try await repository.insert(
                NewSticker(kind: .emoji, name: "没有字符"),
                at: 1
            )
            XCTFail("Emoji 表情缺少字符时必须拒绝写入")
        } catch let error as StickerError {
            XCTAssertEqual(error, .missingEmoji)
        }
    }

    func testInsertImageRequiresAttachment() async throws {
        do {
            _ = try await repository.insert(
                NewSticker(kind: .staticImage, name: "没有附件的图片表情"),
                at: 1
            )
            XCTFail("图片表情缺少附件时必须拒绝写入")
        } catch let error as StickerError {
            XCTAssertEqual(error, .missingAttachment)
        }
    }

    func testEmojiDeduplicatesByCharacter() async throws {
        let first = try await repository.insert(
            NewSticker(kind: .emoji, name: "微笑", emoji: "😊", semantics: "轻松", semanticsSource: .catalog),
            at: 1
        )
        let second = try await repository.insert(
            NewSticker(kind: .emoji, name: "又一个微笑", emoji: "😊"),
            at: 2
        )
        XCTAssertEqual(first.id, second.id, "同一 Emoji 字符不得产生重复行")
        let count = try await repository.count(kind: .emoji)
        XCTAssertEqual(count, 1)
    }

    func testImageDeduplicatesByAttachment() async throws {
        try await seedAttachment(id: "a1", sha: "sha-a1")
        let first = try await repository.insert(
            NewSticker(packID: nil, kind: .gif, name: "拍桌", attachmentID: "a1"),
            at: 1
        )
        let second = try await repository.insert(
            NewSticker(packID: nil, kind: .staticImage, name: "拍桌-重复导入", attachmentID: "a1"),
            at: 2
        )
        XCTAssertEqual(first.id, second.id, "同一附件只能有一条表情索引")
        XCTAssertEqual(first.kind, .gif, "首次记录形态不被后续导入覆盖")
    }

    func testEnsurePackIsIdempotent() async throws {
        let first = try await repository.ensurePack(
            name: "内置 Emoji", source: .builtin, sourceURL: nil, license: nil
        )
        let second = try await repository.ensurePack(
            name: "内置 Emoji", source: .builtin, sourceURL: nil, license: nil
        )
        XCTAssertEqual(first.id, second.id)
        let packs = try await repository.packs()
        XCTAssertEqual(packs.count, 1)
    }

    func testFavoriteToggleAndFavoritesList() async throws {
        let a = try await repository.insert(NewSticker(kind: .emoji, name: "赞", emoji: "👍"), at: 1)
        let b = try await repository.insert(NewSticker(kind: .emoji, name: "踩", emoji: "👎"), at: 2)

        try await repository.setFavorite(id: a.id, isFavorite: true, at: 10)
        try await repository.setFavorite(id: b.id, isFavorite: true, at: 20)

        let favorites = try await repository.favorites(limit: 10)
        XCTAssertEqual(favorites.map(\.id), [b.id, a.id], "收藏按更新时间倒序")

        try await repository.setFavorite(id: a.id, isFavorite: false, at: 30)
        let after = try await repository.favorites(limit: 10)
        XCTAssertEqual(after.map(\.id), [b.id])
    }

    func testFavoriteUnknownStickerThrowsNotFound() async throws {
        do {
            try await repository.setFavorite(id: "missing", isFavorite: true, at: 1)
            XCTFail("不存在的表情必须报错")
        } catch let error as StickerError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testRecentDeduplicatesAndOrdersByLastUse() async throws {
        let a = try await repository.insert(NewSticker(kind: .emoji, name: "A", emoji: "😄"), at: 1)
        let b = try await repository.insert(NewSticker(kind: .emoji, name: "B", emoji: "😭"), at: 2)

        try await repository.recordUsage(stickerID: a.id, messageID: nil, at: 100)
        try await repository.recordUsage(stickerID: b.id, messageID: nil, at: 200)
        try await repository.recordUsage(stickerID: a.id, messageID: nil, at: 300)

        let recent = try await repository.recent(limit: 10)
        XCTAssertEqual(recent.map(\.id), [a.id, b.id], "最近使用按最后一次使用时间倒序且去重")
    }

    func testRecordUsageSameMillisIsIdempotent() async throws {
        let a = try await repository.insert(NewSticker(kind: .emoji, name: "A", emoji: "🍚"), at: 1)
        try await repository.recordUsage(stickerID: a.id, messageID: nil, at: 100)
        try await repository.recordUsage(stickerID: a.id, messageID: nil, at: 100)
        let usage = try await repository.usage(stickerID: a.id, limit: 10)
        XCTAssertEqual(usage.count, 1)
    }

    func testSearchMatchesNameTagsAndSemantics() async throws {
        _ = try await repository.insert(
            NewSticker(kind: .emoji, name: "微笑", tags: "开心", emoji: "😊", semantics: "轻松友好"),
            at: 1
        )
        _ = try await repository.insert(
            NewSticker(kind: .emoji, name: "大哭", tags: "难过", emoji: "😭", semantics: "委屈"),
            at: 2
        )

        let byTag = try await repository.search(query: "难过", limit: 10)
        let bySemantics = try await repository.search(query: "轻松", limit: 10)
        let byName = try await repository.search(query: "微", limit: 10)
        let blank = try await repository.search(query: "   ", limit: 10)
        XCTAssertEqual(byTag.count, 1)
        XCTAssertEqual(bySemantics.count, 1)
        XCTAssertEqual(byName.count, 1)
        XCTAssertEqual(blank.count, 0, "空关键词不返回结果")
    }

    func testSoftDeleteHidesStickerButKeepsRow() async throws {
        let a = try await repository.insert(NewSticker(kind: .emoji, name: "A", emoji: "🎉"), at: 1)
        try await repository.delete(id: a.id, at: 50)

        let all = try await repository.stickers(packID: nil, kind: nil, limit: 10, offset: 0)
        let alive = try await repository.count(kind: nil)
        XCTAssertTrue(all.isEmpty)
        XCTAssertEqual(alive, 0)
        let row = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM stickers WHERE id = ?", arguments: [a.id]) ?? 0
        }
        XCTAssertEqual(row, 1, "软删只置 deleted_at，不物理删行")
        // 重复删除幂等
        try await repository.delete(id: a.id, at: 60)
    }

    func testUpdateSemanticsRecordsSource() async throws {
        let a = try await repository.insert(NewSticker(kind: .emoji, name: "A", emoji: "🤔"), at: 1)
        try await repository.updateSemantics(id: a.id, semantics: "在琢磨", source: .vision, at: 20)
        let updated = try await repository.sticker(id: a.id)
        XCTAssertEqual(updated?.semantics, "在琢磨")
        XCTAssertEqual(updated?.semanticsSource, .vision)
    }

    func testRenameRejectsEmptyName() async throws {
        let a = try await repository.insert(NewSticker(kind: .emoji, name: "A", emoji: "✨"), at: 1)
        do {
            try await repository.rename(id: a.id, name: "  ", tags: "", at: 2)
            XCTFail("空名称必须拒绝")
        } catch let error as StickerError {
            XCTAssertEqual(error, .emptyName)
        }
    }

    func testPagingByKind() async throws {
        for (index, emoji) in ["😊", "😄", "😭", "😤"].enumerated() {
            _ = try await repository.insert(
                NewSticker(kind: .emoji, name: "e\(index)", emoji: emoji),
                at: Int64(index + 1)
            )
        }
        try await seedAttachment(id: "a1", sha: "sha-a1")
        _ = try await repository.insert(
            NewSticker(kind: .staticImage, name: "图", attachmentID: "a1"),
            at: 100
        )

        let emojiPage = try await repository.stickers(packID: nil, kind: .emoji, limit: 2, offset: 0)
        XCTAssertEqual(emojiPage.count, 2)
        XCTAssertTrue(emojiPage.allSatisfy { $0.kind == .emoji })
        let staticCount = try await repository.count(kind: .staticImage)
        XCTAssertEqual(staticCount, 1)
    }
}
