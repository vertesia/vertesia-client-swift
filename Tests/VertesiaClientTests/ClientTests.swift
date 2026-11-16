import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import VertesiaClient

@Test func builderUsesIndependentQueryOptionsAndEscapesPathParameters() throws {
    let client = VertesiaClient(
        bearerToken: "test-token",
        baseURL: try #require(URL(string: "https://example.com/api/v1/"))
    )
    let base = client.agentRuns.listAgentRunsRequest().status([.running, .completed])
    let first = base.limit(10).build()
    let second = base.limit(20).build()
    let firstQuery = try #require(URLComponents(string: first.URLString)?.queryItems)
    let secondQuery = try #require(URLComponents(string: second.URLString)?.queryItems)
    #expect(firstQuery.filter { $0.name == "status" }.compactMap(\.value) == ["running", "completed"])
    #expect(firstQuery.first { $0.name == "limit" }?.value == "10")
    #expect(secondQuery.first { $0.name == "limit" }?.value == "20")
    #expect(first.headers["x-api-version"] == VertesiaClient.apiVersion)

    let run = client.agentRuns.getAgentRunWithRequestBuilder(agentRunId: "folder/run%2F")
    #expect(run.URLString == "https://example.com/api/v1/agents/folder%2Frun%252F")
}

@Test func tokenProviderRunsForEachRequest() async throws {
    let tokens = TestTokenProvider()
    let client = VertesiaClient(
        baseURL: try #require(URL(string: "https://example.com/api/v1"))
    ) { await tokens.next() }
    client.apiConfiguration.requestBuilderFactory = StubRequestBuilderFactory()

    let first = try await client.agentRuns.listAgentRuns()
    let second = try await client.agentRuns.listAgentRunsRequest().execute()
    #expect(first.nextCursor == "test-token-1")
    #expect(second.body.nextCursor == "test-token-2")

    let other = VertesiaClient(bearerToken: "test-token-other")
    other.apiConfiguration.requestBuilderFactory = StubRequestBuilderFactory()
    let separateSession = try await other.agentRuns.listAgentRuns()
    #expect(separateSession.nextCursor == "test-token-other")
}

@Test func cancellationWhileWaitingForAuthenticationPreventsTheRequest() async throws {
    let gate = TokenGate()
    let client = VertesiaClient { await gate.token() }
    client.apiConfiguration.requestBuilderFactory = StubRequestBuilderFactory()
    let call = Task { try await client.agentRuns.listAgentRuns() }
    await gate.waitForRequest()
    call.cancel()
    await gate.release()

    await #expect(throws: ErrorResponse.self) {
        try await call.value
    }
}

@Test func acceptsAdditionalFieldsAndUnknownEnumValues() throws {
    let decoder = JSONDecoder()
    let page = try decoder.decode(
        ListAgentRunsResponse.self,
        from: Data(#"{"items":[],"total_count":0,"added_by_new_server":true}"#.utf8)
    )
    #expect(page.items.isEmpty)
    #expect(try decoder.decode(AgentRunStatus.self, from: Data(#""new_status""#.utf8)) == .unknownDefaultOpenApi)
    #expect(try decoder.decode(AgentMessageType.self, from: Data("7".utf8)) == .answer)
    #expect(try decoder.decode(AgentMessageType.self, from: Data("99".utf8)) == .unknownDefaultOpenApi)
    #expect(throws: DecodingError.self) {
        try decoder.decode(AgentMessageType.self, from: Data(#""99""#.utf8))
    }
}

@Test func unknownDiscriminatedUnionVariantsRoundTripVerbatimAsJSON() throws {
    let decoder = JSONDecoder()
    let data = Data(#"{"run_type":"future","data":{"value":null,"list":[true,2,null]}}"#.utf8)
    let expected = try decoder.decode(JSONValue.self, from: data)
    let result = try decoder.decode(AgentRunResponse.self, from: data)
    #expect(result == .unknownDefaultOpenApi(expected))
    #expect(try decoder.decode(JSONValue.self, from: JSONEncoder().encode(result)) == expected)

    #expect(throws: DecodingError.self) {
        try decoder.decode(AgentRunResponse.self, from: Data(#"{"run_type":"autonomous"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(AgentRunResponse.self, from: Data("{}".utf8))
    }
}

@Test func modelOptionsKeepMixedProviderFieldsAndNulls() throws {
    let decoder = JSONDecoder()
    let data = Data(#"{"_option_id":"new-provider","number_of_images":2,"new_option":null,"vendor":{"nested":null}}"#.utf8)
    let options = try decoder.decode(ModelOptions.self, from: data)
    #expect(options.values["new_option"] == .null)
    #expect(try decoder.decode(JSONValue.self, from: JSONEncoder().encode(options)) == decoder.decode(JSONValue.self, from: data))
}

private actor TestTokenProvider {
    private var calls = 0

    func next() -> String {
        calls += 1
        return "test-token-\(calls)"
    }
}

private actor TokenGate {
    private var pending: CheckedContinuation<String, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func token() async -> String {
        await withCheckedContinuation { continuation in
            pending = continuation
            arrival?.resume()
            arrival = nil
        }
    }

    func waitForRequest() async {
        if pending == nil {
            await withCheckedContinuation { arrival = $0 }
        }
    }

    func release() {
        pending?.resume(returning: "test-token")
        pending = nil
    }
}

private struct StubRequestBuilderFactory: RequestBuilderFactory {
    func getNonDecodableBuilder<T>() -> RequestBuilder<T>.Type {
        URLSessionRequestBuilder<T>.self
    }

    func getBuilder<T: Decodable>() -> RequestBuilder<T>.Type {
        StubRequestBuilder<T>.self
    }
}

private final class StubRequestBuilder<T: Decodable & Sendable>:
    URLSessionDecodableRequestBuilder<T>, @unchecked Sendable {
    override func createURLSession() -> any URLSessionProtocol {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EchoAuthorizationProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class EchoAuthorizationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let version = request.value(forHTTPHeaderField: "x-api-version")
        let status = auth.hasPrefix("Bearer ") && version == VertesiaClient.apiVersion ? 200 : 400
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = """
        {"items":[],"total_count":0,"next_cursor":"\(auth.dropFirst(7))"}
        """
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
