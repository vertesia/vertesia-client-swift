import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif
import Testing
import VertesiaClient

@Suite(.enabled(
    if: ProcessInfo.processInfo.environment["VERTESIA_LIVE_TESTS"] == "1",
    "Set VERTESIA_LIVE_TESTS=1 to run against a Vertesia test project."
))
struct LiveIntegrationTests {
    @Test(.timeLimit(.minutes(1))) func readStudioAndContentEndpoints() async throws {
        let live = try LiveConfiguration()
        let studio = live.studio
        let store = live.store
        let account = try await request("getCurrentAccount") { try await studio.accounts.getCurrentAccount() }
        let project = try await request("getProject") {
            try await studio.projects.getProject(projectId: live.projectID)
        }
        #expect(!account.id.isEmpty)
        #expect(project.id == live.projectID)
        #expect(project.account == account.id)

        let prompts = PromptTemplatesAPI(apiConfiguration: studio.apiConfiguration)
        let promptPage = try await request("listPrompts") { try await prompts.listPrompts(limit: 1) }
        #expect(promptPage.count <= 1)
        let interactions = try await request("listInteractions") { try await studio.interactions.listInteractions(limit: 1) }
        #expect(interactions.count <= 1)

        let objects = try await request("searchObjects") {
            try await store.objects.searchObjects(complexSearchPayload: .init(limit: 1))
        }
        #expect(objects.results.count <= 1)
        let data = DataAPI(apiConfiguration: store.apiConfiguration)
        _ = try await request("listDataStores") { try await data.listDataStores() }
        let workflows = WorkflowDefinitionsAPI(apiConfiguration: store.apiConfiguration)
        _ = try await request("listWorkflowDefinitions") { try await workflows.listWorkflowDefinitions() }
    }

    @Test(.timeLimit(.minutes(1))) func expectedHTTPErrorEnvelopes() async throws {
        let live = try LiveConfiguration()
        let unauthorized = VertesiaClient(bearerToken: "invalid-integration-test-token", baseURL: live.studioURL)
        await #expect(throws: LiveFailure.request("getCurrentAccount", 401, true)) {
            try await request("getCurrentAccount") { try await unauthorized.accounts.getCurrentAccount() }
        }

        let types = ContentObjectTypesAPI(apiConfiguration: live.store.apiConfiguration)
        await #expect(throws: LiveFailure.request("getContentObjectTypeByName", 404, true)) {
            try await request("getContentObjectTypeByName") {
                try await types.getContentObjectTypeByName(name: uniqueName("missing"))
            }
        }
    }

    @Test(.timeLimit(.minutes(2))) func promptAndInteractionLifecycle() async throws {
        let live = try LiveConfiguration()
        let studio = live.studio
        let executionConfig = try live.executionConfig()
        let prompts = PromptTemplatesAPI(apiConfiguration: studio.apiConfiguration)
        let promptName = uniqueName("prompt")
        try await withLiveResource("createPrompt", id: \PromptTemplate.id, cleanup: { id in
            _ = try await clean("deletePrompt") { try await prompts.deletePrompt(ptId: id) }
        }, create: {
            try await prompts.createPrompt(promptTemplateCreatePayload: .init(
                name: promptName, tags: ["integration-test", "openapi-swift"],
                role: .user, content: #"return "Hello, " + name.trim() + "!";"#, contentType: .jst,
                inputSchema: .init(
                    type: .string("object"), properties: ["name": .init(type: .string("string"))],
                    _required: ["name"]
                )
            ))
        }) { template in
            #expect(template.name == promptName)
            await #expect(throws: LiveFailure.request("renderPrompt", 422, true)) {
                try await request("renderPrompt") {
                    try await prompts.renderPrompt(ptId: template.id, requestBody: [:])
                }
            }
            let rendered = try await request("renderPrompt") {
                try await prompts.renderPrompt(ptId: template.id, requestBody: ["name": .string("Swift")])
            }
            #expect(rendered.rendered == "Hello, Swift!")

            let interactionName = uniqueName("interaction")
            try await withLiveResource("createInteraction", id: \Interaction.id, cleanup: { id in
                _ = try await clean("deleteInteraction") { try await studio.interactions.deleteInteraction(interactionId: id) }
            }, create: {
                try await studio.interactions.createInteraction(interactionCreatePayload: .init(
                    status: .draft, prompts: [.init(type: .template, template: .typeString(template.id))],
                    name: interactionName, visibility: ._private, tags: ["integration-test", "openapi-swift"]
                ))
            }) { interaction in
                let fetched = try await request("getInteraction") {
                    try await studio.interactions.getInteraction(interactionId: interaction.id)
                }
                #expect(fetched.name == interactionName)
                let execution = try await request("executeInteraction") {
                    try await studio.interactions.executeInteraction(
                        interactionId: interaction.id,
                        interactionExecutionPayload: .init(
                            data: .dictionary(["name": .string("Swift")]), config: executionConfig
                        )
                    )
                }
                #expect(!execution.id.isEmpty)
                #expect(execution.status == .completed || execution.status == .failed)
            }
        }
    }

    @Test(.timeLimit(.minutes(2))) func dataStoreLifecycle() async throws {
        let data = DataAPI(apiConfiguration: try LiveConfiguration().store.apiConfiguration)
        let name = uniqueName("store")
        try await withLiveResource("createDataStore", id: \DataStore.id, cleanup: { id in
            _ = try await clean("deleteDataStore") { try await data.deleteDataStore(storeId: id) }
        }, create: {
            try await data.createDataStore(createDataStorePayload: .init(
                name: name, tags: ["integration-test", "openapi-swift"]
            ))
        }) { store in
            let fetched = try await request("getDataStore") { try await data.getDataStore(storeId: store.id) }
            #expect(fetched.id == store.id)
            #expect(fetched.name == name)
            let schema = try await request("getDataStoreSchema") {
                try await data.getDataStoreSchema(storeId: store.id, format: .full)
            }
            guard case .typeDataStoreFullSchemaResponse = schema else {
                Issue.record("getDataStoreSchema did not decode the requested full schema.")
                return
            }
        }
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    @Test(.timeLimit(.minutes(3))) func uploadsAndIntakesAnImage() async throws {
        let store = try LiveConfiguration().store
        let types = ContentObjectTypesAPI(apiConfiguration: store.apiConfiguration)
        try await withLiveResource("createContentObjectType", id: \ContentObjectType.id, cleanup: { id in
            _ = try await clean("deleteContentObjectType") { try await types.deleteContentObjectType(typeId: id) }
        }, create: {
            try await types.createContentObjectType(createContentObjectTypePayload: .init(
                status: .active, isChunkable: false,
                intake: .init(extraction: .init(enabled: false), embeddings: .init(text: false, image: false, properties: false)),
                objectSchema: ["type": .string("object"), "properties": .dictionary([:])],
                name: uniqueName("image-type"), tags: ["integration-test", "openapi-swift", "file-intake"]
            ))
        }) { type in
            try await intakeImage(store: store, typeID: type.id)
        }
    }

    private func intakeImage(store: VertesiaClient, typeID: String) async throws {
        let name = uniqueName("image") + ".jpg"
        let path = "openapi-swift-tests/\(name)"
        let upload = try await request("getFileUploadUrl") {
            try await store.files.getFileUploadUrl(getUploadUrlPayload: .init(name: name, id: path, mimeType: "image/jpeg"))
        }
        try await maintainingCleanup({
            _ = try await clean("deleteProjectFile") { try await store.files.deleteProjectFile(path: path) }
        }) {
            try await uploadJPEG(to: upload.url)
            try await withLiveResource("createObject", id: \ContentObjectApiResponse.id, cleanup: { id in
                _ = try await clean("deleteObject") { try await store.objects.deleteObject(objectId: id) }
            }, create: {
                try await store.objects.createObject(createContentObjectPayload: .init(
                    security: ["content:read": ["project:*"], "content:write": ["project:*"], "content:delete": ["project:*"]],
                    content: .init(source: upload.id, type: "image/jpeg", name: name),
                    name: name, tags: ["integration-test", "openapi-swift", "file-intake"], type: typeID
                ))
            }) { object in
                let deadline = ContinuousClock.now + .seconds(100)
                while ContinuousClock.now < deadline {
                    let current = try await request("getObject") { try await store.objects.getObject(objectId: object.id) }
                    if current.status == .ready || current.status == .completed {
                        let source = try await request("getObjectContentSource") {
                            try await store.objects.getObjectContentSource(objectId: object.id)
                        }
                        #expect(source.source?.isEmpty == false)
                        return
                    }
                    if current.status == .failed {
                        Issue.record("Image intake entered the failed state.")
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                Issue.record("Image intake did not reach a ready state before the deadline.")
            }
        }
    }

    private func uploadJPEG(to signedURL: String) async throws {
        guard let url = URL(string: signedURL), url.scheme == "https", url.host != nil else {
            throw LiveFailure.configuration("Signed upload did not return an HTTPS URL.")
        }
        var put = URLRequest(url: url, timeoutInterval: 30)
        put.httpMethod = "PUT"
        put.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let jpeg = try imageFixture()
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.upload(for: put, from: jpeg)
        } catch {
            throw LiveFailure.request("signedImageUpload", -1, false)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw LiveFailure.request("signedImageUpload", status, false)
        }
    }

    private func imageFixture() throws -> Data {
        let pixels = try #require(CGContext(
            data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        pixels.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        pixels.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        let jpeg = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(pixels.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        return jpeg as Data
    }
    #endif

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["VERTESIA_TEST_AGENT_RUN_ID"]?.isEmpty == false,
            "Set VERTESIA_TEST_AGENT_RUN_ID to an existing run with persisted messages in this test project."
        ),
        .timeLimit(.minutes(1))
    )
    func readsAgentRunAndStreamsAPersistedMessage() async throws {
        let live = try LiveConfiguration()
        let store = live.store
        let id = try #require(ProcessInfo.processInfo.environment["VERTESIA_TEST_AGENT_RUN_ID"])
        let page = try await request("listAgentRuns") {
            try await store.agentRuns.listAgentRunsRequest().id(id).limit(1).execute().body
        }
        #expect(page.items.map(runID) == [id])
        let run = try await request("getAgentRun") { try await store.agentRuns.getAgentRun(agentRunId: id) }
        #expect(runID(run) == id)

        #if canImport(Darwin)
        for try await event in store.streamAgentRun(agentRunId: id) {
            if let timestamp = event.message.ts {
                #expect(event.cursor.since == timestamp)
                return
            }
        }
        Issue.record("Expected a persisted event from the configured agent run.")
        #endif
    }

    private func runID(_ run: AgentRunResponse) -> String? {
        switch run {
        case .typeAutonomousRunResponse(let value): value.id
        case .typeProgrammaticRunResponse(let value): value.id
        case .typeSupervisedRunResponse(let value): value.id
        case .unknownDefaultOpenApi: nil
        }
    }
}

private struct LiveConfiguration {
    private let token: String
    let studioURL: URL
    let storeURL: URL
    let projectID: String

    var studio: VertesiaClient { VertesiaClient(bearerToken: token, baseURL: studioURL) }
    var store: VertesiaClient { VertesiaClient(bearerToken: token, baseURL: storeURL) }

    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["VERTESIA_BEARER_TOKEN"], !token.isEmpty,
              !token.hasPrefix("sk-"), !token.hasPrefix("pk-"),
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { throw LiveFailure.configuration("VERTESIA_BEARER_TOKEN must contain an issued access token.") }
        guard let project = env["VERTESIA_PROJECT_ID"], !project.isEmpty else {
            throw LiveFailure.configuration("VERTESIA_PROJECT_ID must identify the test project.")
        }
        studioURL = try Self.apiURL(env["VERTESIA_STUDIO_URL"] ?? env["VERTESIA_API_URL"])
        storeURL = try Self.apiURL(env["VERTESIA_ZENO_URL"] ?? env["VERTESIA_API_URL"])
        self.token = token
        projectID = project
    }

    func executionConfig() throws -> InteractionExecutionConfiguration? {
        let env = ProcessInfo.processInfo.environment
        let environment = env["VERTESIA_TEST_EXECUTION_ENVIRONMENT"]
        let model = env["VERTESIA_TEST_EXECUTION_MODEL"]
        if environment == nil, model == nil { return nil }
        guard let environment, !environment.isEmpty, let model, !model.isEmpty else {
            throw LiveFailure.configuration("Set both VERTESIA_TEST_EXECUTION_ENVIRONMENT and VERTESIA_TEST_EXECUTION_MODEL.")
        }
        return .init(environment: environment, model: model)
    }

    private static func apiURL(_ value: String?) throws -> URL {
        guard let value, var url = URLComponents(string: value),
              url.scheme == "https", url.host != nil, url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil
        else { throw LiveFailure.configuration("Set VERTESIA_API_URL or both split HTTPS API URLs.") }
        if url.path.hasSuffix("/") { url.path.removeLast() }
        if !url.path.hasSuffix("/api/v1") { url.path += "/api/v1" }
        guard let endpoint = url.url else { throw LiveFailure.configuration("Invalid live API URL.") }
        return endpoint
    }
}

private enum LiveFailure: Error, Equatable {
    case configuration(String)
    case request(String, Int, Bool)
    case decoding(String, [String])
}

private func uniqueName(_ resource: String) -> String {
    "integration-resource-swift-sdk-\(resource)-\(UUID().uuidString.lowercased())"
}

private func request<T>(_ operation: String, _ execute: () async throws -> T) async throws -> T {
    do {
        return try await execute()
    } catch let ErrorResponse.error(status, data, response, underlying) {
        if (200..<300).contains(status), let decoding = underlying as? DecodingError {
            let path: [any CodingKey]
            switch decoding {
            case .keyNotFound(let key, let context): path = context.codingPath + [key]
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                path = context.codingPath
            @unknown default: path = []
            }
            throw LiveFailure.decoding(operation, path.map(\.stringValue))
        }
        let errorBody = data.flatMap { try? JSONDecoder().decode(ModelErrorResponse.self, from: $0) }
        let validEnvelope = (response as? HTTPURLResponse)?.statusCode == status
            && errorBody?.status == status && errorBody?.error.isEmpty == false
        throw LiveFailure.request(operation, status, validEnvelope)
    }
}

private func clean<T>(_ operation: String, _ execute: () async throws -> T) async throws -> T? {
    do {
        return try await request(operation, execute)
    } catch LiveFailure.request(_, 404, _) {
        return nil
    }
}

private struct CreatedResourceID: Decodable { let id: String }

private func withLiveResource<T>(
    _ operation: String, id: KeyPath<T, String>,
    cleanup: @escaping @Sendable (String) async throws -> Void,
    create: () async throws -> T, _ work: (T) async throws -> Void
) async throws {
    let resource = try await request(operation) {
        do {
            return try await create()
        } catch let error as ErrorResponse {
            // A successful creation can still fail in the generated decoder.
            if case .error(let status, let data?, _, _) = error, (200..<300).contains(status),
               let created = try? JSONDecoder().decode(CreatedResourceID.self, from: data) {
                do {
                    try await Task { try await cleanup(created.id) }.value
                } catch {
                    Issue.record("Could not clean up after a live response decode failure: \(error)")
                }
            }
            throw error
        }
    }
    let resourceID = resource[keyPath: id]
    try await maintainingCleanup({ try await cleanup(resourceID) }) {
        try await work(resource)
    }
}

private func maintainingCleanup(
    _ cleanup: @escaping @Sendable () async throws -> Void, _ work: () async throws -> Void
) async throws {
    do {
        try await work()
    } catch {
        do {
            try await Task { try await cleanup() }.value
        } catch {
            Issue.record("Could not clean up live test resource: \(error)")
        }
        throw error
    }
    try await Task { try await cleanup() }.value
}
