import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
import Testing
@testable import VertesiaClient

@Test func apiKeyIsExchangedOnceForConcurrentRequestsAndRenewed() async throws {
    let transport = TokenTestTransport([
        .init(#"{"token":"issued-1","token_type":"Bearer","expires_in":100}"#),
        .init(#"{"token":"issued-2","token_type":"Bearer","expires_in":100}"#),
    ])
    let apiURL = URL(string: "https://api-preview.eu1.vertesia.io/api/v1")!
    let client = try VertesiaClient(
        apiKey: "sk-dummy", baseURL: apiURL, tokenServerURL: nil, endpoint: transport.endpoint
    )

    async let first = client.authorization(at: apiURL)
    async let second = client.authorization(at: apiURL)
    let headers = try await [first, second]
    #expect(headers == ["Bearer issued-1", "Bearer issued-1"])
    let exchange = try #require(transport.requests.value.first)
    #expect(transport.requests.value.count == 1)
    #expect(exchange.url?.absoluteString == "https://sts.eu1.vertesia.io/token/issue")
    #expect(exchange.value(forHTTPHeaderField: "Authorization") == "Bearer sk-dummy")
    #expect(exchange.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let request = try JSONDecoder().decode(ApiKeyTokenRequest.self, from: #require(exchange.httpBody))
    #expect(request.type == .apikey)
    #expect(request.key == "sk-dummy")

    transport.advance(seconds: 91)
    #expect(try await client.authorization(at: apiURL) == "Bearer issued-2")
    #expect(transport.requests.value.count == 2)
}

@Test func rejectsUnsafeTokenEndpointsAndUnsupportedKeysBeforeSending() throws {
    let customAPI = URL(string: "https://api.example.org/api/v1")!
    #expect(throws: VertesiaTokenError.invalidConfiguration("tokenServerURL")) {
        try VertesiaClient(apiKey: "sk-dummy", baseURL: customAPI)
    }
    #expect(throws: VertesiaTokenError.invalidConfiguration("apiKey")) {
        try VertesiaClient(apiKey: "pk-dummy")
    }
    #expect(throws: VertesiaTokenError.invalidConfiguration("tokenServerURL")) {
        try VertesiaClient(apiKey: "sk-dummy", tokenServerURL: URL(string: "http://example.org")!)
    }
    #expect(throws: VertesiaTokenError.invalidConfiguration("tokenServerURL")) {
        try VertesiaClient(apiKey: "sk-dummy", tokenServerURL: URL(string: "https://secret@example.org")!)
    }
    #expect(throws: VertesiaTokenError.invalidConfiguration("baseURL")) {
        try VertesiaClient(apiKey: "sk-dummy", baseURL: URL(string: "http://api.example.org/api/v1")!)
    }
}

enum FederationAuthMode: CaseIterable, Sendable {
    case connectionOnly, secretBasic, secretPost, privateKeyJWT
}

@Test(arguments: FederationAuthMode.allCases)
func federationExchangeUsesTheSelectedClientAuthentication(_ mode: FederationAuthMode) async throws {
    let apiURL = URL(string: "https://api.us1.vertesia.io/api/v1")!
    let tenant = URL(string: "https://sts.us1.vertesia.io/oauth/tenant/test/token")!
    let transport = TokenTestTransport([
        .init(#"{"access_token":"federated","token_type":"Bearer","expires_in":100,"issued_token_type":"urn:ietf:params:oauth:token-type:access_token"}"#),
    ])
    let auth: VertesiaFederationClientAuthentication?
    switch mode {
    case .connectionOnly: auth = nil
    case .secretBasic: auth = .clientSecretBasic(clientID: "desktop:id", secret: "secret +")
    case .secretPost: auth = .clientSecretPost(clientID: "desktop:id", secret: "secret +")
    case .privateKeyJWT: auth = .privateKeyJWT(clientID: "desktop:id") { "client.assertion.jwt" }
    }
    let federation = VertesiaFederationOptions(
        connectionID: "connection", projectID: "project", resource: apiURL,
        scope: "openid content:read", tokenEndpoint: tenant, clientAuthentication: auth
    ) { "subject.assertion.jwt" }
    let client = try VertesiaClient(federation: federation, baseURL: apiURL, tokenServerURL: nil, endpoint: transport.endpoint)
    #expect(try await client.authorization(at: apiURL) == "Bearer federated")
    let request = try #require(transport.requests.value.first)
    #expect(request.url == tenant)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    let form = try request.formFields()
    #expect(form["subject_token"] == "subject.assertion.jwt")
    #expect(form["subject_token_type"] == "urn:ietf:params:oauth:token-type:jwt")
    #expect(form["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange")
    #expect(form["project_id"] == "project")
    #expect(form["resource"] == apiURL.absoluteString)
    #expect(form["scope"] == "openid content:read")
    #expect(form["federation_connection_id"] == "connection")
    switch mode {
    case .connectionOnly:
        #expect(form.count == 7)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    case .secretBasic:
        let encoded = Data("desktop%3Aid:secret+%2B".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(encoded)")
        #expect(form["client_id"] == nil)
        #expect(form["client_secret"] == nil)
    case .secretPost:
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(form["client_id"] == "desktop:id")
        #expect(form["client_secret"] == "secret +")
    case .privateKeyJWT:
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(form["client_id"] == "desktop:id")
        #expect(form["client_assertion"] == "client.assertion.jwt")
        #expect(form["client_assertion_type"] == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
    }
}

@Test func federationRenewsWithFreshAssertionsAndRedactsRemoteErrors() async throws {
    let apiURL = VertesiaClient.defaultBaseURL
    let transport = TokenTestTransport([
        .init(#"{"access_token":"first","token_type":"Bearer","expires_in":10,"issued_token_type":"urn:ietf:params:oauth:token-type:access_token"}"#),
        .init(#"{"error":"invalid_grant","error_description":"raw assertion echoed by server"}"#, status: 400),
        .init(#"{"access_token":"next","token_type":"Bearer","expires_in":100,"issued_token_type":"urn:ietf:params:oauth:token-type:access_token"}"#),
    ])
    let assertions = OpenAPIMutex(0)
    let options = VertesiaFederationOptions(connectionID: "connection", projectID: "project", resource: apiURL) {
        assertions.withValue {
            $0 += 1
            return "assertion-\($0)"
        }
    }
    let client = try VertesiaClient(federation: options, baseURL: apiURL, tokenServerURL: nil, endpoint: transport.endpoint)
    #expect(try await client.authorization(at: apiURL) == "Bearer first")
    transport.advance(seconds: 10)
    await #expect(throws: VertesiaTokenError.rejected(status: 400, code: "invalid_grant")) {
        try await client.authorization(at: apiURL)
    }
    await #expect(throws: VertesiaTokenError.rejected(status: 400, code: "invalid_grant")) {
        try await client.authorization(at: apiURL)
    }
    #expect(transport.requests.value.count == 2)
    transport.advance(seconds: 1)
    #expect(try await client.authorization(at: apiURL) == "Bearer next")
    #expect(try transport.requests.value.map { try $0.formFields()["subject_token"] } == [
        "assertion-1", "assertion-2", "assertion-3",
    ])
}

#if canImport(Darwin) && canImport(CryptoKit)
extension ApplePlatformTests {
    @Test func oauthValidatesCallbackAndRotatesCredentials() async throws {
        let transport = TokenTestTransport([
            .init(#"{"access_token":"oauth-1","token_type":"Bearer","expires_in":100,"refresh_token":"refresh-1"}"#),
            .init(#"{"access_token":"oauth-2","token_type":"Bearer","expires_in":100,"refresh_token":"refresh-2"}"#),
            .init(#"{"access_token":"oauth-3","token_type":"Bearer","expires_in":100}"#),
        ])
        let resource = VertesiaClient.defaultBaseURL
        let oauth = try VertesiaOAuthClient(
            clientID: "app + id",
            authorizationEndpoint: URL(string: "https://login.example.org/oauth/authorize?issuer=dev")!,
            tokenEndpoint: URL(string: "https://sts.example.org/oauth/token")!,
            redirectURI: URL(string: "org.example.desktop:/callback?fixed=desktop")!,
            resource: resource, scopes: ["offline_access", "content:read"],
            issuer: URL(string: "https://sts.example.org")!, endpoint: transport.endpoint
        )
        let login = try oauth.beginAuthorization()
        let query = try #require(URLComponents(url: login.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        let parameters = try decodeForm(query)
        let state = try #require(parameters["state"])
        #expect(state.count == 43)
        #expect(parameters["client_id"] == "app + id")
        #expect(parameters["response_type"] == "code")
        #expect(parameters["code_challenge_method"] == "S256")
        #expect(parameters["issuer"] == "dev")
        #expect(parameters["scope"] == "offline_access content:read")

        let untrusted = URL(string: "org.example.desktop:/callback?fixed=desktop&code=wrong&state=wrong&iss=https://sts.example.org")!
        await #expect(throws: VertesiaTokenError.invalidCallback) {
            try await oauth.completeAuthorization(login, callback: untrusted)
        }
        let mixedIssuer = URL(string: "org.example.desktop:/callback?fixed=desktop&code=wrong&state=\(state)&iss=https://other.example.org")!
        await #expect(throws: VertesiaTokenError.invalidCallback) {
            try await oauth.completeAuthorization(login, callback: mixedIssuer)
        }
        #expect(transport.requests.value.isEmpty)

        let callback = URL(string: "org.example.desktop:/callback?fixed=desktop&state=\(state)&code=a%2Bb%26c&iss=https://sts.example.org")!
        let credentials = try await oauth.completeAuthorization(login, callback: callback)
        let codeExchange = try #require(transport.requests.value.first).formFields()
        #expect(codeExchange["grant_type"] == "authorization_code")
        #expect(codeExchange["code"] == "a+b&c")
        #expect(codeExchange["resource"] == resource.absoluteString)
        let verifier = try #require(codeExchange["code_verifier"])
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(challenge == parameters["code_challenge"])

        let persisted = OpenAPIMutex<[String]>([])
        let session = oauth.session(credentials: credentials) { refreshed in
            persisted.withValue { $0.append(refreshed.refreshToken ?? "") }
        }
        let client = VertesiaClient(oauth: session)
        #expect(try await client.authorization(at: resource) == "Bearer oauth-1")
        transport.advance(seconds: 91)
        async let one = client.authorization(at: resource)
        async let two = client.authorization(at: resource)
        let refreshed = try await [one, two]
        #expect(refreshed == ["Bearer oauth-2", "Bearer oauth-2"])
        #expect(transport.requests.value.count == 2)

        transport.advance(seconds: 91)
        #expect(try await client.authorization(at: resource) == "Bearer oauth-3")
        #expect(try transport.requests.value.dropFirst().map { try $0.formFields()["refresh_token"] } == [
            "refresh-1", "refresh-2",
        ])
        #expect(persisted.value == ["refresh-2", "refresh-2"])
        #expect(!(try await session.credentials().description.contains("refresh-2")))
    }
}
#endif

private struct TokenTestTransport: Sendable {
    struct Reply: Sendable {
        let body: String
        let status: Int

        init(_ body: String, status: Int = 200) {
            self.body = body
            self.status = status
        }
    }

    let replies: OpenAPIMutex<[Reply]>
    let requests = OpenAPIMutex<[URLRequest]>([])
    let now = OpenAPIMutex(Date(timeIntervalSince1970: 1_700_000_000))

    init(_ replies: [Reply]) { self.replies = OpenAPIMutex(replies) }

    var endpoint: TokenEndpoint {
        TokenEndpoint(send: { request in
            requests.withValue { $0.append(request) }
            let reply = replies.withValue { $0.isEmpty ? Reply("{}", status: 500) : $0.removeFirst() }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (Data(reply.body.utf8), response)
        }, clock: { now.value })
    }

    func advance(seconds: TimeInterval) {
        now.withValue { $0 = $0.addingTimeInterval(seconds) }
    }
}

private extension VertesiaClient {
    func authorization(at url: URL) async throws -> String? {
        try await bearerTokenInterceptor.authorize(URLRequest(url: url)).value(forHTTPHeaderField: "Authorization")
    }
}

private extension URLRequest {
    func formFields() throws -> [String: String] {
        let body = try #require(httpBody)
        return try decodeForm(String(decoding: body, as: UTF8.self))
    }
}

private func decodeForm(_ body: String) throws -> [String: String] {
    var url = URLComponents()
    url.percentEncodedQuery = body.replacingOccurrences(of: "+", with: "%20")
    return Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}
