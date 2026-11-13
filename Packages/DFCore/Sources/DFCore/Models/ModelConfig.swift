import Foundation

/// 模型配置。密钥不落在本表，只保存 Keychain 中的引用名 keyRef。
public struct ModelConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var providerKind: String
    public var baseURL: String
    public var modelID: String
    public var keyRef: String
    public var isDefault: Bool
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: String = UUID().uuidString,
        name: String,
        providerKind: String = "openaiCompatible",
        baseURL: String,
        modelID: String,
        keyRef: String = UUID().uuidString,
        isDefault: Bool = false,
        createdAt: Int64 = Clock.nowMillis(),
        updatedAt: Int64 = Clock.nowMillis()
    ) {
        self.id = id
        self.name = name
        self.providerKind = providerKind
        self.baseURL = baseURL
        self.modelID = modelID
        self.keyRef = keyRef
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case providerKind = "provider_kind"
        case baseURL = "base_url"
        case modelID = "model_id"
        case keyRef = "key_ref"
        case isDefault = "is_default"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
