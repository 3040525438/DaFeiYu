import Foundation

/// 附件记录：文件本体存文件系统，库里只存索引与校验和。
///
/// v10 起附带媒体指标：图片宽高、音频/视频时长、缩略图路径。
/// 这些字段一律可空——"没测到"与"0"是两种含义，不能用 0 冒充。
public struct AttachmentRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var sha256: String
    public var kind: String
    public var relPath: String
    public var byteSize: Int64
    public var mime: String
    public var createdAt: Int64
    public var width: Int?
    public var height: Int?
    public var durationMs: Int?
    public var thumbnailRelPath: String?
    public var deletedAt: Int64?

    public var isDeleted: Bool { deletedAt != nil }

    public init(
        id: String = UUID().uuidString,
        sha256: String,
        kind: String,
        relPath: String,
        byteSize: Int64,
        mime: String,
        createdAt: Int64 = Clock.nowMillis(),
        width: Int? = nil,
        height: Int? = nil,
        durationMs: Int? = nil,
        thumbnailRelPath: String? = nil,
        deletedAt: Int64? = nil
    ) {
        self.id = id
        self.sha256 = sha256
        self.kind = kind
        self.relPath = relPath
        self.byteSize = byteSize
        self.mime = mime
        self.createdAt = createdAt
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.thumbnailRelPath = thumbnailRelPath
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sha256
        case kind
        case relPath = "rel_path"
        case byteSize = "byte_size"
        case mime
        case createdAt = "created_at"
        case width
        case height
        case durationMs = "duration_ms"
        case thumbnailRelPath = "thumbnail_rel_path"
        case deletedAt = "deleted_at"
    }
}

public struct StoredAttachment: Sendable, Equatable {
    public var sha256: String
    public var relativePath: String
    public var byteSize: Int64

    public init(sha256: String, relativePath: String, byteSize: Int64) {
        self.sha256 = sha256
        self.relativePath = relativePath
        self.byteSize = byteSize
    }
}
