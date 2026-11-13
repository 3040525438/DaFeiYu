import Foundation

/// 附件记录：文件本体存文件系统，库里只存索引与校验和
public struct AttachmentRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var sha256: String
    public var kind: String
    public var relPath: String
    public var byteSize: Int64
    public var mime: String
    public var createdAt: Int64

    public init(
        id: String = UUID().uuidString,
        sha256: String,
        kind: String,
        relPath: String,
        byteSize: Int64,
        mime: String,
        createdAt: Int64 = Clock.nowMillis()
    ) {
        self.id = id
        self.sha256 = sha256
        self.kind = kind
        self.relPath = relPath
        self.byteSize = byteSize
        self.mime = mime
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sha256
        case kind
        case relPath = "rel_path"
        case byteSize = "byte_size"
        case mime
        case createdAt = "created_at"
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
