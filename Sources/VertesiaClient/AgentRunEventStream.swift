#if canImport(Darwin)
import Foundation

/// A position in a single agent run's message stream. Timestamps are Unix milliseconds.
public struct AgentRunStreamCursor: Sendable, Codable, Equatable {
    public let lastEventID: String?
    public let since: Double?

    public init(lastEventID: String? = nil, since: Double? = nil) {
        self.lastEventID = lastEventID
        self.since = since
    }
}

/// A message and the position from which a subsequent subscription can resume.
public struct AgentRunStreamEvent: Sendable {
    public let message: CompactMessage
    public let cursor: AgentRunStreamCursor
}

public enum AgentRunStreamError: Error, Equatable {
    case invalidURL
    case invalidCursor
    case invalidResponse
    case httpStatus(Int)
    case unexpectedContentType(String?)
    case disconnected
}

extension VertesiaClient {
    /// Opens the run's history and live messages when the iterator is first read.
    /// Save each event's cursor after processing it to resume a later subscription.
    public func streamAgentRun(
        agentRunId: String,
        resumingFrom cursor: AgentRunStreamCursor = .init()
    ) -> AgentRunEventStream {
        AgentRunEventStream(
            agentRunId: agentRunId,
            cursor: cursor,
            configuration: apiConfiguration,
            authorize: bearerTokenInterceptor.authorize,
            isArchived: {
                switch try await agentRuns.getAgentRun(agentRunId: agentRunId) {
                case .typeAutonomousRunResponse(let run): run.archiveState == .complete
                case .typeProgrammaticRunResponse(let run): run.archiveState == .complete
                case .typeSupervisedRunResponse(let run): run.archiveState == .complete
                case .unknownDefaultOpenApi: false
                }
            }
        )
    }
}

/// A pull-based sequence. Cancel the consuming task or release its iterator to close the connection.
public struct AgentRunEventStream: AsyncSequence, Sendable {
    public typealias Element = AgentRunStreamEvent

    let agentRunId: String
    let cursor: AgentRunStreamCursor
    let configuration: VertesiaClientAPIConfiguration
    let authorize: @Sendable (URLRequest) async throws -> URLRequest
    var isArchived: @Sendable () async throws -> Bool
    var session: URLSession = .shared
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(self)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let stream: AgentRunEventStream
        private let decoder = JSONDecoder()
        private var connection: Connection?
        private var cursor: AgentRunStreamCursor
        private let initialFloor: Double?
        private var messagesAtCursor: Set<CompactMessage> = []
        private var retryHint: Duration?
        private var retries = 0
        private var confirmedArchive = false
        private var finished = false

        fileprivate init(_ stream: AgentRunEventStream) {
            self.stream = stream
            var since = stream.cursor.since
            if since == nil, let eventID = stream.cursor.lastEventID, let timestamp = Double(eventID),
               timestamp.isFinite, timestamp > 0 {
                since = timestamp
            }
            cursor = .init(lastEventID: stream.cursor.lastEventID, since: since)
            initialFloor = since
        }

        public mutating func next() async throws -> Element? {
            guard !finished else { return nil }
            do {
                return try await readNext()
            } catch {
                finish()
                throw error
            }
        }

        private mutating func readNext() async throws -> Element? {
            while true {
                try Task.checkCancellation()
                if connection == nil {
                    let request = try await stream.authorize(makeRequest())
                    try Task.checkCancellation()
                    do {
                        connection = try await open(request)
                    } catch {
                        try await reconnect(after: error)
                        continue
                    }
                    guard connection != nil else {
                        finish()
                        return nil
                    }
                }

                guard let connection else { return nil }
                let frame: ServerSentEventParser.Event?
                do {
                    frame = try await connection.nextEvent()
                } catch {
                    try await reconnect(after: error)
                    continue
                }
                try Task.checkCancellation()
                guard let frame else {
                    if confirmedArchive {
                        finish()
                        return nil
                    }
                    // A clean EOF can be a finite archive or a proxy closing a live
                    // connection. After confirming the archive, reconnect once to drain it.
                    confirmedArchive = (try? await stream.isArchived()) == true
                    try await reconnect(after: AgentRunStreamError.disconnected)
                    continue
                }
                guard frame.name == "message", !frame.data.isEmpty else { continue }
                let message = try decoder.decode(CompactMessage.self, from: Data(frame.data.utf8))
                if let timestamp = message.ts, timestamp > 0 {
                    if let initialFloor, timestamp < initialFloor { continue }
                    if timestamp == cursor.since {
                        // A fresh subscription already consumed its supplied cursor.
                        if initialFloor == timestamp && messagesAtCursor.isEmpty { continue }
                        guard messagesAtCursor.insert(message).inserted else { continue }
                    } else if timestamp > (cursor.since ?? 0) {
                        messagesAtCursor = [message]
                    }

                    if timestamp >= (cursor.since ?? 0) {
                        let eventID = frame.id ?? cursor.lastEventID
                        cursor = .init(lastEventID: eventID == "" ? nil : eventID, since: timestamp)
                    }
                }
                return AgentRunStreamEvent(message: message, cursor: cursor)
            }
        }

        private func makeRequest() throws -> URLRequest {
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%"))
            guard !stream.agentRunId.isEmpty, stream.agentRunId != ".", stream.agentRunId != "..",
                  let id = stream.agentRunId.addingPercentEncoding(withAllowedCharacters: allowed),
                  var components = URLComponents(string: stream.configuration.basePath),
                  components.host != nil, components.query == nil, components.fragment == nil,
                  ["https", "http"].contains(components.scheme?.lowercased() ?? "")
            else {
                throw AgentRunStreamError.invalidURL
            }
            components.percentEncodedPath += "/agents/\(id)/stream"
            if let timestamp = cursor.since {
                guard stream.cursor.since.map({ $0.isFinite && $0 >= 0 }) != false else { throw AgentRunStreamError.invalidCursor }
                // The server's since filter is exclusive. Overlap the last delivered
                // millisecond so equally timestamped messages can still be replayed.
                let since = messagesAtCursor.isEmpty ? timestamp : Swift.max(0, timestamp - 1)
                var query = [URLQueryItem(name: "since", value: String(since))]
                if since > 0 { query.append(URLQueryItem(name: "skipHistory", value: "true")) }
                components.queryItems = query
            }
            guard let url = components.url else { throw AgentRunStreamError.invalidURL }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            for (key, value) in stream.configuration.customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(nil, forHTTPHeaderField: "Last-Event-ID")
            if let eventID = cursor.lastEventID, !eventID.isEmpty {
                guard !eventID.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
                    throw AgentRunStreamError.invalidCursor
                }
                request.setValue(eventID, forHTTPHeaderField: "Last-Event-ID")
            }
            return request
        }

        private func open(_ request: URLRequest) async throws -> Connection? {
            let (bytes, response) = try await stream.session.bytes(for: request)
            do {
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw AgentRunStreamError.invalidResponse }
                if response.statusCode == 204 {
                    bytes.task.cancel()
                    return nil
                }
                guard response.statusCode == 200 else { throw AgentRunStreamError.httpStatus(response.statusCode) }
                guard response.mimeType?.lowercased() == "text/event-stream" else {
                    throw AgentRunStreamError.unexpectedContentType(response.mimeType)
                }
                return Connection(bytes)
            } catch {
                bytes.task.cancel()
                throw error
            }
        }

        private mutating func reconnect(after error: any Error) async throws {
            try Task.checkCancellation()
            if let connection {
                retryHint = connection.retryHint ?? retryHint
                if connection.openedAt.duration(to: .now) >= .seconds(5) { retries = 0 }
                connection.task.cancel()
                self.connection = nil
            }
            guard Self.canRetry(error), retries < 10 else { throw error }
            let backoff = Duration.seconds(Swift.min(1 << retries, 30))
            let delay = Swift.max(backoff, retryHint ?? .zero)
            retries += 1
            try await stream.sleep(delay)
        }

        private static func canRetry(_ error: any Error) -> Bool {
            switch error {
            case AgentRunStreamError.disconnected: true
            case AgentRunStreamError.httpStatus(let status):
                [401, 408, 409, 429].contains(status) || (500...599).contains(status)
            case let error as URLError:
                [
                    .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable
                ].contains(error.code)
            default: false
            }
        }

        private mutating func finish() {
            finished = true
            connection?.task.cancel()
            connection = nil
        }
    }
}

private final class Connection {
    let task: URLSessionTask
    let openedAt = ContinuousClock.now
    private var bytes: URLSession.AsyncBytes.Iterator
    private var parser = ServerSentEventParser()
    var retryHint: Duration? { parser.retry }

    init(_ bytes: URLSession.AsyncBytes) {
        task = bytes.task
        self.bytes = bytes.makeAsyncIterator()
    }

    deinit { task.cancel() }

    func nextEvent() async throws -> ServerSentEventParser.Event? {
        let task = self.task
        return try await withTaskCancellationHandler {
            while let byte = try await bytes.next() {
                if let event = parser.consume(byte) { return event }
            }
            return nil
        } onCancel: {
            task.cancel()
        }
    }
}
#endif
