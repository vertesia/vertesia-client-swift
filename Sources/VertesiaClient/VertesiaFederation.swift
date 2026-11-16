import Foundation

/// Optional confidential-client authentication defined by the federation connection.
public enum VertesiaFederationClientAuthentication: Sendable, CustomStringConvertible {
    case clientSecretBasic(clientID: String, secret: String)
    case clientSecretPost(clientID: String, secret: String)
    case privateKeyJWT(clientID: String, assertionProvider: @Sendable () async throws -> String)

    public var description: String {
        switch self {
        case .clientSecretBasic: "client_secret_basic"
        case .clientSecretPost: "client_secret_post"
        case .privateKeyJWT: "private_key_jwt"
        }
    }
}

/// Settings for exchanging a fresh identity-provider assertion for a scoped Vertesia bearer token.
public struct VertesiaFederationOptions: Sendable {
    public let connectionID: String
    public let projectID: String
    public let resource: URL
    public let scope: String?
    public let subjectTokenType: String
    public let tokenEndpoint: URL?
    public let clientAuthentication: VertesiaFederationClientAuthentication?
    let subjectTokenProvider: @Sendable () async throws -> String

    public init(
        connectionID: String,
        projectID: String,
        resource: URL,
        scope: String? = nil,
        subjectTokenType: String = "urn:ietf:params:oauth:token-type:jwt",
        tokenEndpoint: URL? = nil,
        clientAuthentication: VertesiaFederationClientAuthentication? = nil,
        subjectTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.connectionID = connectionID
        self.projectID = projectID
        self.resource = resource
        self.scope = scope
        self.subjectTokenType = subjectTokenType
        self.tokenEndpoint = tokenEndpoint
        self.clientAuthentication = clientAuthentication
        self.subjectTokenProvider = subjectTokenProvider
    }

    func resolveEndpoint(baseURL: URL, tokenServerURL: URL?) throws -> URL {
        guard !connectionID.isEmpty, !projectID.isEmpty, !subjectTokenType.isEmpty else {
            throw VertesiaTokenError.invalidConfiguration("federation")
        }
        try TokenEndpoint.validate(resource, field: "resource")
        switch clientAuthentication {
        case let .clientSecretBasic(clientID, secret), let .clientSecretPost(clientID, secret):
            guard !clientID.isEmpty, !secret.isEmpty else {
                throw VertesiaTokenError.invalidConfiguration("clientAuthentication")
            }
        case let .privateKeyJWT(clientID, _):
            guard !clientID.isEmpty else { throw VertesiaTokenError.invalidConfiguration("clientAuthentication") }
        case nil:
            break
        }
        if let tokenEndpoint {
            try TokenEndpoint.validate(tokenEndpoint, field: "tokenEndpoint")
            return tokenEndpoint
        }
        return try TokenEndpoint.server(baseURL: baseURL, override: tokenServerURL).appendingPathComponent("oauth/token")
    }

    func exchange(at url: URL, endpoint: TokenEndpoint) async throws -> VertesiaOAuthCredentials {
        let subjectToken = try await Self.readAssertion(subjectTokenProvider)
        var fields = [
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "subject_token": subjectToken,
            "subject_token_type": subjectTokenType,
            "federation_connection_id": connectionID,
            "project_id": projectID,
            "resource": resource.absoluteString,
        ]
        fields["scope"] = scope
        var authorization: String?
        switch clientAuthentication {
        case let .clientSecretBasic(clientID, secret):
            let value = "\(TokenEndpoint.form(clientID)):\(TokenEndpoint.form(secret))"
            authorization = "Basic \(Data(value.utf8).base64EncodedString())"
        case let .clientSecretPost(clientID, secret):
            fields["client_id"] = clientID
            fields["client_secret"] = secret
        case let .privateKeyJWT(clientID, assertionProvider):
            fields["client_id"] = clientID
            fields["client_assertion_type"] = TokenEndpoint.jwtAssertion
            fields["client_assertion"] = try await Self.readAssertion(assertionProvider)
        case nil:
            break
        }
        return try await endpoint.exchangeForm(at: url, fields: fields, authorization: authorization, federation: true)
    }

    private static func readAssertion(_ provider: @Sendable () async throws -> String) async throws -> String {
        do {
            let assertion = try await provider()
            try Task.checkCancellation()
            guard !assertion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VertesiaTokenError.assertionProviderFailed
            }
            return assertion
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw VertesiaTokenError.assertionProviderFailed
        }
    }
}

extension VertesiaClient {
    /// Exchanges assertions through the named federation policy and renews the resulting bearer token on demand.
    public init(
        federation: VertesiaFederationOptions,
        baseURL: URL = Self.defaultBaseURL,
        tokenServerURL: URL? = nil
    ) throws {
        try self.init(federation: federation, baseURL: baseURL, tokenServerURL: tokenServerURL, endpoint: TokenEndpoint())
    }

    init(
        federation: VertesiaFederationOptions, baseURL: URL, tokenServerURL: URL?, endpoint: TokenEndpoint
    ) throws {
        try TokenEndpoint.validate(baseURL, field: "baseURL")
        let url = try federation.resolveEndpoint(baseURL: baseURL, tokenServerURL: tokenServerURL)
        let source = RefreshingBearerToken(clock: endpoint.clock) { _ in
            try await federation.exchange(at: url, endpoint: endpoint)
        }
        self.init(baseURL: baseURL) { try await source.credentials().accessToken }
    }

    /// Exchanges a fresh assertion once, for callers that manage their own credential lifecycle.
    public static func exchangeFederationToken(
        _ federation: VertesiaFederationOptions,
        baseURL: URL = Self.defaultBaseURL,
        tokenServerURL: URL? = nil
    ) async throws -> VertesiaOAuthCredentials {
        let url = try federation.resolveEndpoint(baseURL: baseURL, tokenServerURL: tokenServerURL)
        return try await federation.exchange(at: url, endpoint: TokenEndpoint())
    }
}
