#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// A single OAuth sign-in attempt. Open the URL in a system browser and pass the callback back to this SDK.
public struct VertesiaOAuthAuthorization: Sendable, CustomStringConvertible {
    public let url: URL
    fileprivate let state: String
    fileprivate let verifier: String
    fileprivate let tokenEndpoint: URL
    fileprivate let redirectURI: URL
    fileprivate let clientID: String
    fileprivate let resource: URL
    fileprivate let issuer: URL?

    public var description: String { "VertesiaOAuthAuthorization" }
}

/// OAuth authorization code with PKCE and refresh for a registered public client.
public struct VertesiaOAuthClient: Sendable {
    public let clientID: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let redirectURI: URL
    public let resource: URL
    public let scopes: [String]
    public let issuer: URL?
    private let endpoint: TokenEndpoint

    public init(
        clientID: String, authorizationEndpoint: URL, tokenEndpoint: URL, redirectURI: URL,
        resource: URL, scopes: [String] = [], issuer: URL? = nil
    ) throws {
        try self.init(
            clientID: clientID, authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint,
            redirectURI: redirectURI, resource: resource, scopes: scopes, issuer: issuer, endpoint: TokenEndpoint()
        )
    }

    init(
        clientID: String, authorizationEndpoint: URL, tokenEndpoint: URL, redirectURI: URL,
        resource: URL, scopes: [String], issuer: URL?, endpoint: TokenEndpoint
    ) throws {
        guard !clientID.isEmpty else { throw VertesiaTokenError.invalidConfiguration("clientID") }
        try Self.validateRedirect(redirectURI)
        try TokenEndpoint.validate(authorizationEndpoint, field: "authorizationEndpoint", allowsQuery: true)
        try TokenEndpoint.validate(tokenEndpoint, field: "tokenEndpoint")
        try TokenEndpoint.validate(resource, field: "resource")
        if let issuer { try TokenEndpoint.validate(issuer, field: "issuer") }
        self.clientID = clientID
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.redirectURI = redirectURI
        self.resource = resource
        self.scopes = scopes
        self.issuer = issuer
        self.endpoint = endpoint
    }

    public func beginAuthorization() throws -> VertesiaOAuthAuthorization {
        let state = Self.randomURLSafeString()
        let verifier = Self.randomURLSafeString()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "resource", value: resource.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " "))) }
        let existing = components?.queryItems ?? []
        let reserved = Set(items.map(\.name)).union(["scope"])
        guard existing.allSatisfy({ !reserved.contains($0.name) }) else {
            throw VertesiaTokenError.invalidConfiguration("authorizationEndpoint")
        }
        components?.percentEncodedQuery = (existing + items).map {
            "\(TokenEndpoint.form($0.name))=\(TokenEndpoint.form($0.value ?? ""))"
        }.joined(separator: "&")
        guard let url = components?.url else { throw VertesiaTokenError.invalidConfiguration("authorizationEndpoint") }
        return VertesiaOAuthAuthorization(
            url: url, state: state, verifier: verifier, tokenEndpoint: tokenEndpoint,
            redirectURI: redirectURI, clientID: clientID, resource: resource, issuer: issuer
        )
    }

    /// Validates the redirect and state before exchanging the single-use authorization code.
    public func completeAuthorization(
        _ authorization: VertesiaOAuthAuthorization, callback: URL
    ) async throws -> VertesiaOAuthCredentials {
        guard authorization.tokenEndpoint == tokenEndpoint, authorization.redirectURI == redirectURI,
              authorization.clientID == clientID, authorization.resource == resource,
              authorization.issuer == issuer,
              var components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              var registered = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
              components.fragment == nil
        else { throw VertesiaTokenError.invalidCallback }
        let items = components.queryItems ?? []
        let staticItems = registered.queryItems ?? []
        components.query = nil
        registered.query = nil
        guard components.url == registered.url, item("state", in: items) == authorization.state,
              staticItems.allSatisfy({ expected in items.filter { $0.name == expected.name } == [expected] })
        else {
            throw VertesiaTokenError.invalidCallback
        }
        if let issuer, item("iss", in: items) != issuer.absoluteString {
            throw VertesiaTokenError.invalidCallback
        }
        if items.contains(where: { $0.name == "error" }) { throw VertesiaTokenError.authorizationDenied }
        guard let code = item("code", in: items), !code.isEmpty else { throw VertesiaTokenError.invalidCallback }
        return try await endpoint.exchangeForm(at: tokenEndpoint, fields: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": authorization.verifier,
            "resource": resource.absoluteString,
        ])
    }

    public func refresh(_ refreshToken: String, projectID: String? = nil) async throws -> VertesiaOAuthCredentials {
        guard !refreshToken.isEmpty else { throw VertesiaTokenError.missingRefreshToken }
        var fields = [
            "grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken,
            "resource": resource.absoluteString,
        ]
        fields["project_id"] = projectID
        return try await endpoint.exchangeForm(at: tokenEndpoint, fields: fields, previousRefreshToken: refreshToken)
    }

    /// Keeps a fresh access token for concurrent API calls. Use onRefresh to persist rotated credentials.
    public func session(
        credentials: VertesiaOAuthCredentials,
        onRefresh: @escaping @Sendable (VertesiaOAuthCredentials) async -> Void = { _ in }
    ) -> VertesiaOAuthSession {
        let source = RefreshingBearerToken(initial: credentials, clock: endpoint.clock, onRenewed: onRefresh) { previous in
            guard let refreshToken = previous?.refreshToken else { throw VertesiaTokenError.missingRefreshToken }
            return try await refresh(refreshToken)
        }
        return VertesiaOAuthSession(resource: resource, source: source)
    }

    private static func validateRedirect(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), components.fragment == nil,
              components.user == nil, components.password == nil, !url.absoluteString.contains("*")
        else { throw VertesiaTokenError.invalidConfiguration("redirectURI") }
        let names = components.queryItems?.map(\.name) ?? []
        let responseParameters = ["code", "state", "iss", "error", "error_description", "error_uri"]
        guard Set(names).count == names.count, Set(names).isDisjoint(with: responseParameters) else {
            throw VertesiaTokenError.invalidConfiguration("redirectURI")
        }
        if scheme == "http" || scheme == "https" {
            try TokenEndpoint.validate(url, field: "redirectURI", allowsQuery: true)
        } else if scheme.range(
            of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$"#,
            options: .regularExpression
        ) == nil {
            throw VertesiaTokenError.invalidConfiguration("redirectURI")
        }
    }

    private func item(_ name: String, in items: [URLQueryItem]) -> String? {
        let matches = items.filter { $0.name == name }
        return matches.count == 1 ? matches[0].value : nil
    }

    private static func randomURLSafeString() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct VertesiaOAuthSession: Sendable {
    public let resource: URL
    fileprivate let source: RefreshingBearerToken

    public func credentials() async throws -> VertesiaOAuthCredentials {
        try await source.credentials()
    }
}

extension VertesiaClient {
    /// Uses the OAuth resource as the API base URL.
    public init(oauth session: VertesiaOAuthSession) {
        self.init(baseURL: session.resource) { try await session.credentials().accessToken }
    }
}
#endif
