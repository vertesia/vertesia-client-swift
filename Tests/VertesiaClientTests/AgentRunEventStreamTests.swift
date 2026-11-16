#if canImport(Darwin)
import Foundation
import Testing
@testable import VertesiaClient

@Test @MainActor func reconnectsWithLastEventIDAndTimestampAfterTransientChunks() async throws {
    let fixture = StreamFixture([
        .sse("\u{FEFF}: hello\r\nretry: 7\r\n\r\n"
            + "event: message\r\nid: stored-1\r\ndata: {\"t\":7,\r\ndata: \"ts\":100,\"m\":\"first\"}\r\n\r\n"
            + "id: transient-uuid\ndata: {\"t\":12,\"m\":\"chunk\"}\n\n"
            + "id: incomplete\ndata: {\"t\":7,\"ts\":101}"),
        .sse("id: replayed-uuid\ndata: {\"t\":7,\"ts\":100,\"m\":\"first\"}\n\n"
            + "id: same-timestamp\ndata: {\"t\":7,\"ts\":100,\"m\":\"second\"}\n\n"
            + "id: stored-2\ndata: {\"t\":7,\"ts\":103,\"m\":\"third\"}\n\n"
            + "id: late\ndata: {\"t\":7,\"ts\":98,\"m\":\"late\"}\n\n"),
        .status(204),
    ])
    let tokenCount = OpenAPIMutex(0)
    var stream = fixture.stream {
        let attempt = tokenCount.withValue { value in
            value += 1
            return value
        }
        return "token-\(attempt)"
    }
    let retryDelays = OpenAPIMutex<[Duration]>([])
    stream.sleep = { delay in retryDelays.withValue { $0.append(delay) } }

    var events: [AgentRunStreamEvent] = []
    for try await event in stream { events.append(event) }
    try #require(events.map(\.message.m) == ["first", "chunk", "second", "third", "late"])
    #expect(events[0].cursor == .init(lastEventID: "stored-1", since: 100))
    #expect(events[1].cursor == events[0].cursor)
    #expect(events[3].cursor == .init(lastEventID: "stored-2", since: 103))
    #expect(events[4].cursor == events[3].cursor)

    let requests = fixture.requests
    #expect(requests.count == 3)
    #expect(requests.map { $0.value(forHTTPHeaderField: "Last-Event-ID") } == [nil, "stored-1", "stored-2"])
    #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-1", "Bearer token-2", "Bearer token-3"])
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "text/event-stream" })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-api-version") == VertesiaClient.apiVersion })
    #expect(requests.map { $0.url?.path } == Array(repeating: "/api/v1/agents/\(StreamFixture.runID)/stream", count: 3))
    #expect(requests.map { $0.query("since").flatMap { Double($0) } } == [nil, 99, 102])
    #expect(requests.map { $0.query("skipHistory") } == [nil, "true", "true"])
    #expect(retryDelays.value == [.seconds(1), .seconds(2)])
}

@Test func resumesCallerCursorAndAcceptsServerRetryHint() async throws {
    let fixture = StreamFixture([
        .sse(": heartbeat\nretry: 5000\n\n"),
        .status(204),
    ])
    var stream = fixture.stream(resumingFrom: .init(lastEventID: "1700000000000")) { "token" }
    let retryDelays = OpenAPIMutex<[Duration]>([])
    stream.sleep = { delay in retryDelays.withValue { $0.append(delay) } }
    var iterator = stream.makeAsyncIterator()

    #expect(try await iterator.next() == nil)
    #expect(fixture.requests.count == 2)
    #expect(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Last-Event-ID") == "1700000000000" })
    #expect(fixture.requests.allSatisfy { $0.query("since").flatMap { Double($0) } == 1_700_000_000_000 })
    #expect(retryDelays.value == [.seconds(5)])
}

@Test func reconnectsAfterAnAbruptNetworkFailure() async throws {
    let fixture = StreamFixture([.networkLoss, .status(204)])
    let stream = fixture.stream(resumingFrom: .init(lastEventID: "stored-id", since: 100)) { "token" }
    var iterator = stream.makeAsyncIterator()

    #expect(try await iterator.next() == nil)
    #expect(fixture.requests.count == 2)
    #expect(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Last-Event-ID") == "stored-id" })
    #expect(fixture.requests.allSatisfy { $0.query("since").flatMap { Double($0) } == 100 })
}

@Test func finishesAnArchivedReplayAfterDrainingIt() async throws {
    let fixture = StreamFixture([
        .sse("id: 100\ndata: {\"t\":7,\"ts\":100}\n\n"),
        .sse("id: 100\ndata: {\"t\":7,\"ts\":100}\n\nid: 101\ndata: {\"t\":7,\"ts\":101}\n\n"),
    ])
    var stream = fixture.stream { "token" }
    stream.isArchived = { true }
    var iterator = stream.makeAsyncIterator()

    #expect(try await iterator.next()?.message.ts == 100)
    #expect(try await iterator.next()?.message.ts == 101)
    #expect(try await iterator.next() == nil)
    #expect(fixture.requests.count == 2)
}

@Test func renewsTokenAfter401AndRejectsNonSSEContent() async throws {
    let fixture = StreamFixture([.status(401), .status(200, contentType: "text/html")])
    let counter = OpenAPIMutex(0)
    let stream = fixture.stream {
        counter.withValue { value in
            value += 1
            return "token-\(value)"
        }
    }
    var iterator = stream.makeAsyncIterator()

    await #expect(throws: AgentRunStreamError.unexpectedContentType("text/html")) { try await iterator.next() }
    #expect(fixture.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-1", "Bearer token-2"])
    #expect(try await iterator.next() == nil)
}

@Test func limitsRetriesOnAnUnavailableServer() async throws {
    let fixture = StreamFixture(Array(repeating: .status(503), count: 11))
    var stream = fixture.stream { "token" }
    let retryDelays = OpenAPIMutex<[Duration]>([])
    stream.sleep = { delay in retryDelays.withValue { $0.append(delay) } }
    var iterator = stream.makeAsyncIterator()

    await #expect(throws: AgentRunStreamError.httpStatus(503)) { try await iterator.next() }
    #expect(fixture.requests.count == 11)
    #expect(retryDelays.value == [1, 2, 4, 8, 16, 30, 30, 30, 30, 30].map { .seconds($0) })
}

@Test(.timeLimit(.minutes(1))) func readsBeforeEOFAndCancelsAnOpenConnection() async throws {
    let fixture = StreamFixture([.sse("id: initial\ndata: {\"t\":7,\"ts\":100}\n\n", staysOpen: true)])
    let clientRead = AsyncStream<Double?>.makeStream()
    let stream = fixture.stream { "token" }
    let reader = Task {
        defer { clientRead.continuation.finish() }
        for try await event in stream {
            clientRead.continuation.yield(event.message.ts)
        }
    }

    defer { reader.cancel() }
    var updates = clientRead.stream.makeAsyncIterator()
    #expect(await updates.next() == 100)
    reader.cancel()
    await #expect(throws: CancellationError.self) { try await reader.value }
    #expect(fixture.requests.count == 1)
}

private extension URLRequest {
    func query(_ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == name }?.value
    }
}

private final class StreamFixture {
    static let runID = "0123456789abcdef01234567"
    private let host = "\(UUID().uuidString.lowercased()).example.com"
    private let script: StubSSEProtocol.Script
    private let session: URLSession

    var requests: [URLRequest] { script.requests.value }

    init(_ responses: [StubSSEProtocol.Reply]) {
        script = .init(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSSEProtocol.self]
        session = URLSession(configuration: configuration)
        StubSSEProtocol.scripts.withValue { $0[host] = script }
    }

    deinit {
        session.invalidateAndCancel()
        let host = self.host
        StubSSEProtocol.scripts.withValue { $0[host] = nil }
    }

    func stream(
        resumingFrom cursor: AgentRunStreamCursor = .init(),
        token: @escaping @Sendable () async throws -> String
    ) -> AgentRunEventStream {
        let client = VertesiaClient(baseURL: URL(string: "https://\(host)/api/v1")!, bearerTokenProvider: token)
        var stream = client.streamAgentRun(agentRunId: Self.runID, resumingFrom: cursor)
        stream.session = session
        stream.isArchived = { false }
        stream.sleep = { _ in }
        return stream
    }
}

private final class StubSSEProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case sse(String, staysOpen: Bool = false)
        case networkLoss
        case status(Int, contentType: String = "application/json")
    }

    final class Script: Sendable {
        let requests = OpenAPIMutex<[URLRequest]>([])
        let responses: OpenAPIMutex<[Reply]>

        init(_ responses: [Reply]) {
            self.responses = OpenAPIMutex(responses)
        }
    }

    static let scripts = OpenAPIMutex<[String: Script]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let script = Self.scripts.value[host] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        script.requests.withValue { $0.append(request) }
        let reply = script.responses.withValue { $0.isEmpty ? .status(418) : $0.removeFirst() }
        switch reply {
        case .sse(let body, let staysOpen):
            respond(url, status: 200, contentType: "text/event-stream; charset=utf-8")
            let data = Data(body.utf8)
            let middle = data.count / 2
            client?.urlProtocol(self, didLoad: data.prefix(middle))
            client?.urlProtocol(self, didLoad: data.dropFirst(middle))
            if !staysOpen { client?.urlProtocolDidFinishLoading(self) }
        case .networkLoss:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .status(let code, let contentType):
            respond(url, status: code, contentType: contentType)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func respond(_ url: URL, status: Int, contentType: String) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    override func stopLoading() {}
}
#endif
