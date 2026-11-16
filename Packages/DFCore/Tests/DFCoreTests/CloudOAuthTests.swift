import XCTest
@testable import DFCore

/// D41 云盘 OAuth 通用层测试：不依赖任何厂商凭证与网络。
final class CloudOAuthTests: XCTestCase {

    private func makeProvider(
        clientID: String = "client-123",
        usesPKCE: Bool = true,
        redirectURI: String = "dafeiyu://oauth/callback"
    ) -> CloudOAuthProvider {
        CloudOAuthProvider(
            id: "generic-drive",
            displayName: "通用云盘",
            authorizationEndpoint: "https://auth.example.com/authorize",
            tokenEndpoint: "https://auth.example.com/token",
            clientID: clientID,
            scopes: ["drive.file", "offline_access"],
            redirectURI: redirectURI,
            usesPKCE: usesPKCE
        )
    }

    // MARK: PKCE

    func testPKCEChallengeMatchesRFC7636Vector() {
        // RFC 7636 附录 B 标准向量
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            OAuthPKCE.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testPKCEPairIsDeterministicWithSeedAndRespectsCharset() {
        let first = OAuthPKCE.pair(seed: "unit-test-seed")
        let second = OAuthPKCE.pair(seed: "unit-test-seed")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.verifier.count, 64)
        let allowed = Set(OAuthPKCE.allowedCharacters)
        XCTAssertTrue(first.verifier.allSatisfy { allowed.contains($0) })
        XCTAssertEqual(first.challenge, OAuthPKCE.challenge(for: first.verifier))
        // 不带 seed 必须每次不同
        XCTAssertNotEqual(OAuthPKCE.pair().verifier, OAuthPKCE.pair().verifier)
    }

    func testPKCELengthIsClamped() {
        XCTAssertEqual(OAuthPKCE.pair(seed: "s", length: 10).verifier.count, 43)
        XCTAssertEqual(OAuthPKCE.pair(seed: "s", length: 500).verifier.count, 128)
    }

    // MARK: 配置与授权 URL

    func testUnconfiguredProviderCannotStartAuthorization() {
        let provider = makeProvider(clientID: "  ")
        XCTAssertEqual(provider.readiness, .notConfigured)
        XCTAssertFalse(provider.isConfigured)
        XCTAssertThrowsError(
            try OAuthFlow.makeAuthorizationRequest(provider: provider, state: "s", verifier: "v")
        ) { error in
            XCTAssertEqual(
                error as? OAuthAuthorizationError,
                .configurationIncomplete(providerID: "generic-drive")
            )
        }
    }

    func testAuthorizationURLContainsStandardParameters() throws {
        let provider = makeProvider()
        let request = try OAuthFlow.makeAuthorizationRequest(
            provider: provider,
            state: "state-abc",
            verifier: "verifier-abc"
        )
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(request.state, "state-abc")
        XCTAssertEqual(request.verifier, "verifier-abc")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("client_id"), "client-123")
        XCTAssertEqual(value("redirect_uri"), "dafeiyu://oauth/callback")
        XCTAssertEqual(value("scope"), "drive.file offline_access")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), OAuthPKCE.challenge(for: "verifier-abc"))
    }

    func testAuthorizationURLWithoutPKCEOmitsChallenge() throws {
        let provider = makeProvider(usesPKCE: false)
        let request = try OAuthFlow.makeAuthorizationRequest(provider: provider, state: "s", verifier: "v")
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(items.first { $0.name == "code_challenge" })
        XCTAssertNil(items.first { $0.name == "code_challenge_method" })
    }

    // MARK: 回调解析

    func testCallbackReturnsAuthorizationCode() throws {
        let callback = URL(string: "dafeiyu://oauth/callback?state=s1&code=abc123")!
        XCTAssertEqual(try OAuthFlow.authorizationCode(from: callback, expectedState: "s1"), "abc123")
    }

    func testCallbackStateMismatchIsRejected() {
        let callback = URL(string: "dafeiyu://oauth/callback?state=other&code=abc123")!
        XCTAssertThrowsError(try OAuthFlow.authorizationCode(from: callback, expectedState: "s1")) { error in
            XCTAssertEqual(error as? OAuthAuthorizationError, .stateMismatch)
        }
    }

    func testCallbackProviderErrorIsSurfaced() {
        let callback = URL(string: "dafeiyu://oauth/callback?error=access_denied&state=s1")!
        XCTAssertThrowsError(try OAuthFlow.authorizationCode(from: callback, expectedState: "s1")) { error in
            XCTAssertEqual(error as? OAuthAuthorizationError, .accessDenied(error: "access_denied"))
        }
    }

    func testCallbackMissingCodeIsRejected() {
        let callback = URL(string: "dafeiyu://oauth/callback?state=s1")!
        XCTAssertThrowsError(try OAuthFlow.authorizationCode(from: callback, expectedState: "s1")) { error in
            XCTAssertEqual(error as? OAuthAuthorizationError, .missingAuthorizationCode)
        }
    }

    // MARK: Token 解析与过期

    func testTokenParserComputesExpiry() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","token_type":"Bearer","expires_in":3600}
        """
        let token = try OAuthTokenParser.parse(Data(json.utf8), now: 1_000_000)
        XCTAssertEqual(token.accessToken, "at")
        XCTAssertEqual(token.refreshToken, "rt")
        XCTAssertEqual(token.expiresAt, 1_000_000 + 3_600_000)
        XCTAssertFalse(token.isExpired(at: 4_599_999))
        XCTAssertTrue(token.isExpired(at: 4_600_000))
    }

    func testTokenParserWithoutExpiryNeverExpires() throws {
        let token = try OAuthTokenParser.parse(Data(#"{"access_token":"at"}"#.utf8), now: 1)
        XCTAssertNil(token.expiresAt)
        XCTAssertFalse(token.isExpired(at: 9_999_999_999))
    }

    func testTokenParserRejectsMalformedResponse() {
        XCTAssertThrowsError(try OAuthTokenParser.parse(Data(#"{"foo":"bar"}"#.utf8), now: 1)) { error in
            XCTAssertEqual(error as? OAuthAuthorizationError, .malformedTokenResponse)
        }
        XCTAssertThrowsError(try OAuthTokenParser.parse(Data("not-json".utf8), now: 1))
    }

    // MARK: Token 存取（SecureStore）

    final class MemorySecureStore: SecureStore, @unchecked Sendable {
        private var values: [String: String] = [:]
        private let lock = NSLock()

        func set(_ value: String, for key: String) throws {
            lock.lock(); defer { lock.unlock() }
            values[key] = value
        }

        func get(_ key: String) throws -> String? {
            lock.lock(); defer { lock.unlock() }
            return values[key]
        }

        func delete(_ key: String) throws {
            lock.lock(); defer { lock.unlock() }
            values.removeValue(forKey: key)
        }
    }

    func testTokenStoreRoundTripAndDelete() throws {
        let store = OAuthTokenStore(store: MemorySecureStore())
        let token = OAuthToken(accessToken: "at", refreshToken: "rt", expiresAt: 42)

        XCTAssertNil(try store.load(providerID: "generic-drive"))
        try store.save(token, providerID: "generic-drive")
        XCTAssertEqual(try store.load(providerID: "generic-drive"), token)
        // 不同厂商互不影响
        XCTAssertNil(try store.load(providerID: "other"))

        try store.delete(providerID: "generic-drive")
        XCTAssertNil(try store.load(providerID: "generic-drive"))
    }

    // MARK: 注册表

    func testRegistryOnlyExposesConfiguredProviders() {
        let ready = makeProvider()
        let missingClient = CloudOAuthProvider(
            id: "not-ready",
            displayName: "未配置",
            authorizationEndpoint: "https://auth.example.com/authorize",
            tokenEndpoint: "https://auth.example.com/token",
            clientID: "",
            scopes: [],
            redirectURI: "dafeiyu://oauth/callback"
        )
        let registry = CloudOAuthRegistry(providers: [ready, missingClient])
        XCTAssertEqual(registry.configuredProviders.map(\.id), ["generic-drive"])
        XCTAssertEqual(registry.provider(id: "not-ready")?.isConfigured, false)
    }
}
