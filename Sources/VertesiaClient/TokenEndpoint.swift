import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum VertesiaTokenError: Error, Equatable {
    case invalidConfiguration(String)
    case invalidCallback
    case authorizationDenied
    case missingRefreshToken
    case assertionProviderFailed
    case transportFailure
    case invalidResponse
    case rejected(status: Int, code: String?)
}

/// Credentials returned by an OAuth authorization or refresh. Store refresh tokens securely.
public struct VertesiaOAuthCredentials: Codable, Sendable, CustomStringConvertible {
    public let accessToken: String
    public let expiresAt: Date
    public let refreshToken: String?
    public let scope: String?

    public init(accessToken: String, expiresAt: Date, refreshToken: String? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.scope = scope
    }

    public var description: String { "VertesiaOAuthCredentials(expiresAt: \(expiresAt))" }
}

actor RefreshingBearerToken {
    typealias Renewal = @Sendable (VertesiaOAuthCredentials?) async throws -> VertesiaOAuthCredentials

    private var cached: VertesiaOAuthCredentials?
    private var renewAt: Date
    private var pending: Task<VertesiaOAuthCredentials, any Error>?
    private var failure: (error: any Error, retryAt: Date)?
    private let clock: @Sendable () -> Date
    private let onRenewed: @Sendable (VertesiaOAuthCredentials) async -> Void
    private let renew: Renewal

    init(
        initial: VertesiaOAuthCredentials? = nil,
        clock: @escaping @Sendable () -> Date = { .now },
        onRenewed: @escaping @Sendable (VertesiaOAuthCredentials) async -> Void = { _ in },
        renew: @escaping Renewal
    ) {
        cached = initial
        renewAt = Self.renewalDate(initial, now: clock())
        self.clock = clock
        self.onRenewed = onRenewed
        self.renew = renew
    }

    func credentials() async throws -> VertesiaOAuthCredentials {
        try Task.checkCancellation()
        if let cached, clock() < renewAt { return cached }
        if let failure, clock() < failure.retryAt { throw failure.error }
        if let pending {
            let credentials = try await pending.value
            try Task.checkCancellation()
            return credentials
        }

        let previous = cached
        let renew = self.renew
        let task = Task { try await renew(previous) }
        pending = task
        defer { pending = nil }

        let credentials: VertesiaOAuthCredentials
        do {
            credentials = try await task.value
        } catch {
            if !(error is CancellationError) {
                failure = (error, clock().addingTimeInterval(1))
            }
            throw error
        }
        failure = nil
        cached = credentials
        renewAt = Self.renewalDate(credentials, now: clock())
        await onRenewed(credentials)
        try Task.checkCancellation()
        return credentials
    }

    private static func renewalDate(_ credentials: VertesiaOAuthCredentials?, now: Date) -> Date {
        guard let credentials else { return .distantPast }
        let remaining = credentials.expiresAt.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0, TokenEndpoint.isBearer(credentials.accessToken) else {
            return .distantPast
        }
        return credentials.expiresAt.addingTimeInterval(-min(60, remaining / 10))
    }
}

struct TokenEndpoint: Sendable {
    static let jwt = "urn:ietf:params:oauth:token-type:jwt"
    static let accessToken = "urn:ietf:params:oauth:token-type:access_token"
    static let jwtAssertion = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

    typealias SendRequest = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    var send: SendRequest = { request in
        try await URLSession.shared.data(for: request, delegate: RejectTokenRedirects())
    }
    var clock: @Sendable () -> Date = { .now }

    func exchangeForm(
        at url: URL,
        fields: [String: String],
        authorization: String? = nil,
        federation: Bool = false,
        previousRefreshToken: String? = nil
    ) async throws -> VertesiaOAuthCredentials {
        let fields = fields.sorted { $0.key < $1.key }.map { "\(Self.form($0.key))=\(Self.form($0.value))" }
        let response = try await exchange(
            url, body: Data(fields.joined(separator: "&").utf8),
            contentType: "application/x-www-form-urlencoded", authorization: authorization
        )
        guard let token = response.wire.accessToken else { throw VertesiaTokenError.invalidResponse }
        if federation {
            guard response.wire.issuedTokenType == Self.accessToken,
                  response.wire.refreshToken == nil,
                  let expiresIn = response.wire.expiresIn, (1...86_400).contains(expiresIn)
            else { throw VertesiaTokenError.invalidResponse }
        }
        return try credentials(from: response, token: token, previousRefreshToken: previousRefreshToken)
    }

    func exchangeAPIKey(at url: URL, key: String) async throws -> VertesiaOAuthCredentials {
        let body = try JSONEncoder().encode(ApiKeyTokenRequest(type: .apikey, key: key))
        let response = try await exchange(url, body: body, contentType: "application/json", authorization: "Bearer \(key)")
        guard let token = response.wire.token else { throw VertesiaTokenError.invalidResponse }
        return try credentials(from: response, token: token)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let token: String?
        let tokenType: String
        let expiresIn: Double?
        let refreshToken: String?
        let issuedTokenType: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case token, scope
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case issuedTokenType = "issued_token_type"
        }
    }

    private struct Rejection: Decodable {
        let error: String

        var knownCode: String? {
            [
                "invalid_grant", "invalid_client", "invalid_scope", "unauthorized_client", "invalid_target",
                "invalid_request", "temporarily_unavailable", "unsupported_grant_type", "access_denied",
            ].contains(error) ? error : nil
        }
    }

    private func exchange(
        _ url: URL, body: Data, contentType: String, authorization: String?
    ) async throws -> (wire: TokenResponse, startedAt: Date) {
        try Task.checkCancellation()
        let startedAt = clock()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw VertesiaTokenError.transportFailure
        }
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        guard let http = response as? HTTPURLResponse else { throw VertesiaTokenError.invalidResponse }
        guard http.statusCode == 200 else {
            let code = data.count <= 65_536 ? (try? decoder.decode(Rejection.self, from: data))?.knownCode : nil
            throw VertesiaTokenError.rejected(status: http.statusCode, code: code)
        }
        guard data.count <= 65_536, let token = try? decoder.decode(TokenResponse.self, from: data) else {
            throw VertesiaTokenError.invalidResponse
        }
        return (token, startedAt)
    }

    private func credentials(
        from response: (wire: TokenResponse, startedAt: Date),
        token: String,
        previousRefreshToken: String? = nil
    ) throws -> VertesiaOAuthCredentials {
        let wire = response.wire
        guard Self.isBearer(token), wire.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              wire.expiresIn.map({ $0.isFinite && $0 > 0 }) != false,
              wire.refreshToken?.isEmpty != true
        else { throw VertesiaTokenError.invalidResponse }

        let relativeExpiry = wire.expiresIn.map { response.startedAt.addingTimeInterval($0) }
        let expiresAt = [relativeExpiry, Self.jwtExpiry(token)].compactMap { $0 }.min()
        guard let expiresAt, expiresAt > clock() else { throw VertesiaTokenError.invalidResponse }
        return VertesiaOAuthCredentials(
            accessToken: token, expiresAt: expiresAt,
            refreshToken: wire.refreshToken ?? previousRefreshToken, scope: wire.scope
        )
    }

    static func isBearer(_ value: String) -> Bool {
        let body = value.utf8.prefix { $0 != 61 }
        return !body.isEmpty && body.allSatisfy { byte in
            isUnreserved(byte) || byte == 43 || byte == 47
        } && value.utf8.dropFirst(body.count).allSatisfy { $0 == 61 }
    }

    static func form(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var bytes: [UInt8] = []
        for byte in value.utf8 {
            if isUnreserved(byte) {
                bytes.append(byte)
            } else if byte == 32 {
                bytes.append(43)
            } else {
                bytes += [37, hex[Int(byte >> 4)], hex[Int(byte & 15)]]
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || [45, 46, 95, 126].contains(byte)
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.utf8.count % 4) % 4)
        struct Claims: Decodable { let exp: Double }
        guard let bytes = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(Claims.self, from: bytes), claims.exp.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: claims.exp)
    }

    static func validate(_ url: URL, field: String, allowsQuery: Bool = false) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              allowsQuery || components.query == nil,
              components.scheme?.lowercased() == "https" ||
                (components.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
        else { throw VertesiaTokenError.invalidConfiguration(field) }
    }

    static func server(baseURL: URL, override: URL?) throws -> URL {
        if let override {
            try validate(override, field: "tokenServerURL")
            return override
        }
        let host = baseURL.host()?.lowercased() ?? ""
        let labels = host.split(separator: ".")
        guard baseURL.scheme?.lowercased() == "https", baseURL.port == nil || baseURL.port == 443,
              (3...5).contains(labels.count), labels.suffix(2).elementsEqual(["vertesia", "io"]),
              labels.first == "api" || labels.first == "api-preview"
        else { throw VertesiaTokenError.invalidConfiguration("tokenServerURL") }
        return URL(string: "https://sts." + labels.dropFirst().joined(separator: "."))!
    }
}

private final class RejectTokenRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension VertesiaClient {
    /// Exchanges an sk- API key through STS and renews its short-lived bearer token on demand.
    public init(apiKey: String, baseURL: URL = Self.defaultBaseURL, tokenServerURL: URL? = nil) throws {
        try self.init(apiKey: apiKey, baseURL: baseURL, tokenServerURL: tokenServerURL, endpoint: TokenEndpoint())
    }

    init(apiKey: String, baseURL: URL, tokenServerURL: URL?, endpoint: TokenEndpoint) throws {
        try TokenEndpoint.validate(baseURL, field: "baseURL")
        guard apiKey.hasPrefix("sk-"), apiKey.utf8.count > 3, TokenEndpoint.isBearer(apiKey) else {
            throw VertesiaTokenError.invalidConfiguration("apiKey")
        }
        let sts = try TokenEndpoint.server(baseURL: baseURL, override: tokenServerURL)
        let url = sts.appendingPathComponent("token/issue")
        let source = RefreshingBearerToken(clock: endpoint.clock) { _ in
            try await endpoint.exchangeAPIKey(at: url, key: apiKey)
        }
        self.init(baseURL: baseURL) { try await source.credentials().accessToken }
    }
}
