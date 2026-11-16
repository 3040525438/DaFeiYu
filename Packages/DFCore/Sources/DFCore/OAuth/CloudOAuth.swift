import Foundation

// MARK: - D41 云盘 OAuth 通用层（不绑定任何厂商）
//
// 设计边界：
// 1. 本层只做「授权码 + PKCE」的通用协议实现，不包含任何厂商 SDK、不内置任何 Client ID；
// 2. 没有厂商凭证时 `readiness == .notConfigured`，调用方必须显示"未接入"，不得静默降级；
// 3. Token 只允许写入 `SecureStore`（iOS 为 Keychain），本层不打印、不落普通数据库；
// 4. 错误信息面向普通用户，不包含 Token、授权码或完整 URL 参数。

/// 接入状态。只有 `.ready` 才允许发起授权。
public enum CloudOAuthReadiness: String, Sendable, Equatable {
    case notConfigured = "not_configured"
    case ready
}

/// 通用 OAuth 厂商配置。字段全部来自用户在设置页手填，缺任一项即视为未接入。
public struct CloudOAuthProvider: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var clientID: String
    public var scopes: [String]
    public var redirectURI: String
    public var usesPKCE: Bool

    public init(
        id: String,
        displayName: String,
        authorizationEndpoint: String,
        tokenEndpoint: String,
        clientID: String,
        scopes: [String] = [],
        redirectURI: String = "",
        usesPKCE: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.usesPKCE = usesPKCE
    }

    public var readiness: CloudOAuthReadiness {
        let client = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let redirect = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty, !redirect.isEmpty,
              let authorize = URL(string: authorizationEndpoint), authorize.scheme != nil,
              let token = URL(string: tokenEndpoint), token.scheme != nil else {
            return .notConfigured
        }
        return .ready
    }

    public var isConfigured: Bool { readiness == .ready }
}

/// 授权流程错误。文案可直接展示给用户。
public enum OAuthAuthorizationError: Error, Equatable, CustomStringConvertible {
    case configurationIncomplete(providerID: String)
    case stateMismatch
    case accessDenied(error: String?)
    case missingAuthorizationCode
    case malformedTokenResponse
    case providerHTTPError(status: Int)

    public var description: String {
        switch self {
        case .configurationIncomplete:
            return "该云盘尚未完成配置，请先在设置中填写客户端 ID 与回调地址"
        case .stateMismatch:
            return "授权校验失败（state 不一致），请重新发起授权"
        case .accessDenied(let error):
            return "授权未完成" + (error.map { "：\($0)" } ?? "")
        case .missingAuthorizationCode:
            return "授权回调缺少授权码，请重试"
        case .malformedTokenResponse:
            return "授权服务返回的数据无法识别，请稍后重试"
        case .providerHTTPError(let status):
            return "授权服务返回异常（HTTP \(status)），请稍后重试"
        }
    }
}

// MARK: - PKCE

public struct OAuthPKCEPair: Sendable, Equatable {
    public var verifier: String
    public var challenge: String

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }
}

public enum OAuthPKCE {
    /// RFC 7636 允许字符集
    public static let allowedCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    /// `base64url(SHA256(verifier))`，无填充
    public static func challenge(for verifier: String) -> String {
        let hex = SHA256.hash(Data(verifier.utf8))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return base64URL(Data(bytes))
    }

    /// 生成 verifier/challenge。`seed` 仅用于测试复现；生产必须不传。
    public static func pair(seed: String? = nil, length: Int = 64) -> OAuthPKCEPair {
        let size = min(max(length, 43), 128)
        let verifier = generateVerifier(seed: seed, length: size)
        return OAuthPKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    private static func generateVerifier(seed: String?, length: Int) -> String {
        var material = ""
        if let seed, !seed.isEmpty {
            var counter = 0
            while material.count < length {
                material += SHA256.hash("\(seed)#\(counter)")
                counter += 1
            }
        } else {
            while material.count < length {
                material += UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    + String(Clock.nowMillis())
            }
        }
        let allowed = Set(allowedCharacters)
        let filtered = material.filter { allowed.contains($0) }
        return String(filtered.prefix(length))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - 授权请求与回调

public struct OAuthAuthorizationRequest: Sendable, Equatable {
    public var url: URL
    public var state: String
    public var verifier: String

    public init(url: URL, state: String, verifier: String) {
        self.url = url
        self.state = state
        self.verifier = verifier
    }
}

public enum OAuthFlow {
    /// 构造授权页 URL。缺配置直接抛错，绝不返回半成品链接。
    public static func makeAuthorizationRequest(
        provider: CloudOAuthProvider,
        state: String,
        verifier: String
    ) throws -> OAuthAuthorizationRequest {
        guard provider.isConfigured,
              var components = URLComponents(string: provider.authorizationEndpoint) else {
            throw OAuthAuthorizationError.configurationIncomplete(providerID: provider.id)
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: provider.clientID),
            URLQueryItem(name: "redirect_uri", value: provider.redirectURI),
            URLQueryItem(name: "state", value: state)
        ]
        if !provider.scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: provider.scopes.joined(separator: " ")))
        }
        if provider.usesPKCE {
            items.append(URLQueryItem(name: "code_challenge", value: OAuthPKCE.challenge(for: verifier)))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        components.queryItems = (components.queryItems ?? []) + items
        guard let url = components.url else {
            throw OAuthAuthorizationError.configurationIncomplete(providerID: provider.id)
        }
        return OAuthAuthorizationRequest(url: url, state: state, verifier: verifier)
    }

    /// 解析回调 URL：先判错误，再校验 state，最后取授权码。
    public static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error") {
            throw OAuthAuthorizationError.accessDenied(error: error)
        }
        guard let state = value("state"), state == expectedState else {
            throw OAuthAuthorizationError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty else {
            throw OAuthAuthorizationError.missingAuthorizationCode
        }
        return code
    }
}

// MARK: - Token

public struct OAuthToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String
    /// 过期时间（毫秒）。`nil` 表示服务端未给出有效期。
    public var expiresAt: Int64?

    public init(accessToken: String, refreshToken: String? = nil, tokenType: String = "Bearer", expiresAt: Int64? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
    }

    public func isExpired(at millis: Int64) -> Bool {
        guard let expiresAt else { return false }
        return millis >= expiresAt
    }
}

public enum OAuthTokenParser {
    /// 解析标准 token 响应（`access_token` / `refresh_token` / `token_type` / `expires_in`）。
    public static func parse(_ data: Data, now: Int64) throws -> OAuthToken {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String, !access.isEmpty else {
            throw OAuthAuthorizationError.malformedTokenResponse
        }
        let refresh = (root["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let type = (root["token_type"] as? String) ?? "Bearer"
        var expiresAt: Int64?
        if let seconds = (root["expires_in"] as? NSNumber)?.doubleValue ?? Double(root["expires_in"] as? String ?? "") {
            expiresAt = now + Int64((seconds * 1000).rounded())
        }
        return OAuthToken(accessToken: access, refreshToken: refresh, tokenType: type, expiresAt: expiresAt)
    }
}

/// Token 只进 SecureStore；key 形如 `oauth.token.<providerID>`。
public struct OAuthTokenStore: Sendable {
    private let store: SecureStore
    private let keyPrefix: String

    public init(store: SecureStore, keyPrefix: String = "oauth.token") {
        self.store = store
        self.keyPrefix = keyPrefix
    }

    private func key(for providerID: String) -> String {
        "\(keyPrefix).\(providerID)"
    }

    public func save(_ token: OAuthToken, providerID: String) throws {
        let data = try JSONEncoder().encode(token)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DFError.database("OAuth Token 编码失败")
        }
        try store.set(text, for: key(for: providerID))
    }

    public func load(providerID: String) throws -> OAuthToken? {
        guard let text = try store.get(key(for: providerID)) else { return nil }
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthToken.self, from: data)
    }

    public func delete(providerID: String) throws {
        try store.delete(key(for: providerID))
    }
}

// MARK: - 注册表

/// 云盘接入注册表：未配置的厂商不会出现在可选项中。
public struct CloudOAuthRegistry: Sendable {
    public var providers: [CloudOAuthProvider]

    public init(providers: [CloudOAuthProvider]) {
        self.providers = providers
    }

    public var configuredProviders: [CloudOAuthProvider] {
        providers.filter { $0.isConfigured }
    }

    public func provider(id: String) -> CloudOAuthProvider? {
        providers.first { $0.id == id }
    }
}
