import Foundation

/// 表情包来源。区分内置、本地导入、在线下载与外部分享导入，
/// 便于界面如实标注"这个表情从哪来"，也便于离线可用性判断。
public enum StickerSource: String, Codable, Sendable, CaseIterable {
    /// 内置（随 App 提供，安装即用、不依赖网络）
    case builtin
    /// 从相册 / 文件 / 剪贴板导入到本地
    case local
    /// 从外部 App（分享菜单 / 链接）导入
    case imported
    /// 从在线表情库下载到本地
    case downloaded
}

/// 表情形态。Emoji 是字符，静态图与 GIF 是文件。
/// 三者必须分开：Emoji 不需要附件，GIF 必须保留动画，不能被当成静态图。
public enum StickerKind: String, Codable, Sendable, CaseIterable {
    case emoji
    case staticImage = "static"
    case gif

    /// 是否需要附件文件
    public var needsFile: Bool { self != .emoji }
}

/// 语义识别来源。用于区分"用户自己写的"与"模型推断的"，
/// 推断结果不得被当作确定事实写入长期记忆。
public enum StickerSemanticsSource: String, Codable, Sendable, CaseIterable {
    /// 没有语义描述
    case none
    /// 内置目录自带（人工维护）
    case catalog
    /// 设备端（文件名 / 标签 / OCR）
    case onDevice
    /// 云端视觉模型推断
    case vision
    /// 用户手动填写
    case user
}

/// 表情包分组（内置包 / 导入包 / 下载包）。
public struct StickerPack: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var source: StickerSource
    /// 在线来源地址（仅 downloaded 有值，用于追溯与授权确认）
    public var sourceURL: String?
    /// 许可证说明（在线资源必须可追溯授权）
    public var license: String?
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: String = UUID().uuidString,
        name: String,
        source: StickerSource,
        sourceURL: String? = nil,
        license: String? = nil,
        createdAt: Int64 = Clock.nowMillis(),
        updatedAt: Int64 = Clock.nowMillis()
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.sourceURL = sourceURL
        self.license = license
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case source
        case sourceURL = "source_url"
        case license
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// 一个表情。
///
/// `semantics` 是"这个表情大致表达什么"的文本描述：
/// - 内置表情由目录给出（`catalog`）；
/// - 用户导入的表情可由设备端 / 云端视觉推断（`onDevice` / `vision`），并如实标注来源；
/// - 用户可手动改写（`user`）。
///
/// 语义推断只是猜测，不得据此直接写入长期记忆。
public struct Sticker: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var packID: String?
    public var kind: StickerKind
    /// 显示名（例如"开心拍桌"）
    public var name: String
    /// 逗号分隔的标签，用于搜索
    public var tags: String
    /// Emoji 字符（仅 `kind == .emoji`）
    public var emoji: String?
    /// 图片附件 id（仅静态图 / GIF，指向 `attachments`）
    public var attachmentID: String?
    /// 语义描述（可为空，表示"还没识别"）
    public var semantics: String
    public var semanticsSource: StickerSemanticsSource
    public var isFavorite: Bool
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    public var isDeleted: Bool { deletedAt != nil }

    /// 搜索用文本（名称 + 标签 + 语义）
    public var searchText: String {
        [name, tags, semantics].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public init(
        id: String = UUID().uuidString,
        packID: String? = nil,
        kind: StickerKind,
        name: String,
        tags: String = "",
        emoji: String? = nil,
        attachmentID: String? = nil,
        semantics: String = "",
        semanticsSource: StickerSemanticsSource = .none,
        isFavorite: Bool = false,
        createdAt: Int64 = Clock.nowMillis(),
        updatedAt: Int64 = Clock.nowMillis(),
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.packID = packID
        self.kind = kind
        self.name = name
        self.tags = tags
        self.emoji = emoji
        self.attachmentID = attachmentID
        self.semantics = semantics
        self.semanticsSource = semanticsSource
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case packID = "pack_id"
        case kind
        case name
        case tags
        case emoji
        case attachmentID = "attachment_id"
        case semantics
        case semanticsSource = "semantics_source"
        case isFavorite = "is_favorite"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

public extension Sticker {
    /// 生成给模型看的简短描述，避免把整段语义塞进提示词。
    var promptLine: String {
        let label = semantics.isEmpty ? name : "\(name)：\(semantics)"
        return "[\(kind.rawValue)] \(label)"
    }
}

/// 新表情的输入参数。
public struct NewSticker: Sendable, Equatable {
    public var packID: String?
    public var kind: StickerKind
    public var name: String
    public var tags: String
    public var emoji: String?
    public var attachmentID: String?
    public var semantics: String
    public var semanticsSource: StickerSemanticsSource

    public init(
        packID: String? = nil,
        kind: StickerKind,
        name: String,
        tags: String = "",
        emoji: String? = nil,
        attachmentID: String? = nil,
        semantics: String = "",
        semanticsSource: StickerSemanticsSource = .none
    ) {
        self.packID = packID
        self.kind = kind
        self.name = name
        self.tags = tags
        self.emoji = emoji
        self.attachmentID = attachmentID
        self.semantics = semantics
        self.semanticsSource = semanticsSource
    }
}

/// 使用记录（"最近使用"依据）。
public struct StickerUsage: Sendable, Equatable, Identifiable {
    public var stickerID: String
    public var usedAt: Int64
    /// 发出的消息 id（可为空：只是预览选择过）
    public var messageID: String?

    public var id: String { "\(stickerID)-\(usedAt)" }

    public init(stickerID: String, usedAt: Int64, messageID: String? = nil) {
        self.stickerID = stickerID
        self.usedAt = usedAt
        self.messageID = messageID
    }
}

// MARK: - 仓储

/// 表情包仓储。
///
/// 口径：
/// - 文件本体一律走 `AttachmentStore` + `attachments` 表（复用去重与引用检查），
///   本仓储只保存表情索引与语义；
/// - 删除表情是软删索引，**不**直接删附件文件（由 D57 引用检查负责）；
/// - "最近使用"按 `sticker_usage.used_at` 倒序去重。
public protocol StickerRepository: Sendable {
    // 包
    func packs() async throws -> [StickerPack]
    @discardableResult
    func ensurePack(name: String, source: StickerSource, sourceURL: String?, license: String?) async throws -> StickerPack

    // 表情
    @discardableResult
    func insert(_ sticker: NewSticker, at millis: Int64) async throws -> Sticker
    func sticker(id: String) async throws -> Sticker?
    /// 按包 / 形态筛选，默认不含已删；按创建时间倒序
    func stickers(packID: String?, kind: StickerKind?, limit: Int, offset: Int) async throws -> [Sticker]
    func count(kind: StickerKind?) async throws -> Int
    func search(query: String, limit: Int) async throws -> [Sticker]
    func favorites(limit: Int) async throws -> [Sticker]
    func recent(limit: Int) async throws -> [Sticker]

    // 更新
    func setFavorite(id: String, isFavorite: Bool, at millis: Int64) async throws
    func updateSemantics(id: String, semantics: String, source: StickerSemanticsSource, at millis: Int64) async throws
    func rename(id: String, name: String, tags: String, at millis: Int64) async throws
    /// 软删（索引层）；附件清理由调用方走引用检查
    func delete(id: String, at millis: Int64) async throws

    // 使用记录
    func recordUsage(stickerID: String, messageID: String?, at millis: Int64) async throws
    func usage(stickerID: String, limit: Int) async throws -> [StickerUsage]
}

public enum StickerError: Error, Equatable, CustomStringConvertible {
    case notFound
    case emptyName
    case missingAttachment
    case missingEmoji
    case unsupportedLink(String)

    public var description: String {
        switch self {
        case .notFound: return "表情不存在"
        case .emptyName: return "表情名称不能为空"
        case .missingAttachment: return "图片表情缺少附件"
        case .missingEmoji: return "Emoji 表情缺少字符"
        case let .unsupportedLink(link): return "暂不支持这种链接：\(link)"
        }
    }
}
