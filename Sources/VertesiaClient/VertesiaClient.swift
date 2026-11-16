import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A session-scoped client for the public Vertesia API.
public struct VertesiaClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.vertesia.io/api/v1")!

    /// The configuration shared by this client's generated API groups.
    public let apiConfiguration: VertesiaClientAPIConfiguration

    public var accounts: AccountsAPI { AccountsAPI(apiConfiguration: apiConfiguration) }
    public var agentRuns: AgentRunsAPI { AgentRunsAPI(apiConfiguration: apiConfiguration) }
    public var collections: CollectionsAPI { CollectionsAPI(apiConfiguration: apiConfiguration) }
    public var files: FilesAPI { FilesAPI(apiConfiguration: apiConfiguration) }
    public var interactionRuns: InteractionRunsAPI { InteractionRunsAPI(apiConfiguration: apiConfiguration) }
    public var interactions: InteractionsAPI { InteractionsAPI(apiConfiguration: apiConfiguration) }
    public var notifications: NotificationsAPI { NotificationsAPI(apiConfiguration: apiConfiguration) }
    public var objects: ObjectsAPI { ObjectsAPI(apiConfiguration: apiConfiguration) }
    public var projects: ProjectsAPI { ProjectsAPI(apiConfiguration: apiConfiguration) }
    public var views: ViewsAPI { ViewsAPI(apiConfiguration: apiConfiguration) }

    /// Creates a client with an existing scoped Vertesia access token.
    public init(bearerToken: String, baseURL: URL = Self.defaultBaseURL) {
        self.init(baseURL: baseURL) { bearerToken }
    }

    /// Uses the app's session to obtain a scoped Vertesia access token for each authenticated request.
    /// Calls may overlap. The provider owns persistence, expiry checks, and refresh coordination.
    public init(
        baseURL: URL = Self.defaultBaseURL,
        bearerTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        let path = baseURL.absoluteString
        apiConfiguration = VertesiaClientAPIConfiguration(
            basePath: path.hasSuffix("/") ? String(path.dropLast()) : path,
            interceptor: BearerTokenInterceptor(provider: bearerTokenProvider)
        )
    }
}

public enum VertesiaAuthenticationError: Error {
    case invalidBearerToken
}

private struct BearerTokenInterceptor: OpenAPIInterceptor {
    let provider: @Sendable () async throws -> String

    func intercept<T>(
        urlRequest: URLRequest,
        urlSession: any URLSessionProtocol,
        requestBuilder: RequestBuilder<T>,
        completion: @Sendable @escaping (Result<URLRequest, any Error>) -> Void
    ) {
        guard requestBuilder.requiresAuthentication else {
            completion(.success(urlRequest))
            return
        }

        Task {
            do {
                let token = try await provider()
                guard !token.isEmpty, token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                    throw VertesiaAuthenticationError.invalidBearerToken
                }
                var request = urlRequest
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                completion(.success(request))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func retry<T>(
        urlRequest: URLRequest,
        urlSession: any URLSessionProtocol,
        requestBuilder: RequestBuilder<T>,
        data: Data?,
        response: URLResponse?,
        error: any Error,
        completion: @Sendable @escaping (OpenAPIInterceptorRetry) -> Void
    ) {
        completion(.dontRetry)
    }
}
