import Foundation
import Testing
import VertesiaClient

@Suite(.enabled(
    if: ProcessInfo.processInfo.environment["VERTESIA_STUDIO_OPENAPI_FIXTURES"]?.isEmpty == false,
    "Set VERTESIA_STUDIO_OPENAPI_FIXTURES to Studio's shared OpenAPI fixture directory."
))
struct StudioOpenAPIFixtureTests {
    private let codec = CodableHelper()

    @Test func decodesCurrentAndNormalizedLegacyUsers() throws {
        let current = try decode(User.self, "user-populated.json")
        #expect(current.id == "68b1779130afe5403a1589ba")
        #expect(current.email == "someone@acme.com")
        #expect(current.externalId == "ext-1")
        #expect(current.phone == "+33100000000")
        #expect(current.compartments == ["eu"])
        #expect(current.properties?["team"] == .string("platform"))
        #expect(current.createdAt == instant("2026-07-30T10:00:00Z"))
        #expect(current.updatedAt == instant("2026-07-30T11:00:00Z"))

        let legacy = try decode(User.self, "user-legacy-normalized.json")
        #expect(legacy.email.isEmpty)
        #expect(legacy.createdAt == instant("2025-08-29T09:49:05Z"))
        #expect(legacy.updatedAt == legacy.createdAt)
        #expect(legacy.phone == nil)
        #expect(legacy.compartments == [])
    }

    @Test func decodesAccountMembersAndRejectsMissingRequiredTimestamps() throws {
        let current = try fixture("user-populated.json")
        let legacy = try fixture("user-legacy-normalized.json")
        let members = try codec.decode([User].self, from: array(current, legacy)).get()
        #expect(members.map(\.email) == ["someone@acme.com", ""])
        #expect(members.last?.createdAt == instant("2025-08-29T09:49:05Z"))

        let missing = Data(#"{"id":"68b1779130afe5403a1589bc","email":"x@acme.com","name":"NoStamps"}"#.utf8)
        #expect(throws: DecodingError.self) { try codec.decode(User.self, from: missing).get() }
        #expect(throws: DecodingError.self) { try codec.decode([User].self, from: array(current, missing)).get() }
    }

    @Test func decodesCurrentAndNormalizedLegacyProjects() throws {
        let current = try decode(Project.self, "project-populated.json")
        #expect(current.name == "Acme")
        #expect(current.namespace == "acme")
        #expect(current.plugins == ["plugin-a"])
        #expect(current.configuration.humanContext == "Investor reporting")
        #expect(current.configuration.embeddings.text?.dimensions == 1024)
        #expect(current.integrations?["github"] == .dictionary(["enabled": .bool(true), "github_app_id": .string("42")]))
        #expect(current.createdAt == instant("2026-07-30T10:00:00Z"))
        #expect(current.updatedAt == instant("2026-07-30T11:00:00Z"))

        let legacy = try decode(Project.self, "project-legacy-normalized.json")
        #expect(legacy.createdBy == "unknown")
        #expect(legacy.updatedBy == "unknown")
        #expect(legacy.createdAt == instant("2017-11-29T03:36:28Z"))
        #expect(legacy.updatedAt == legacy.createdAt)
        #expect(legacy.plugins.isEmpty)
        #expect(legacy.integrations == nil)
        #expect(legacy.configuration.embeddings.text?.enabled == false)
    }

    @Test func retainsNestedIntakePolicyFieldsOnRoundTrip() throws {
        let data = try fixture("content-type-intake-policy.json")
        let policy = try codec.decode(ContentTypeIntakePolicy.self, from: data).get()
        #expect(policy.mode == .programmatic)
        #expect(policy.defaultView == .pdf)
        #expect(policy.extraction?.pageRanges == [[1, 2], [-1, -1]])
        #expect(policy.extraction?.vision?.maxPagesPerCall == 4)
        #expect(policy.extraction?.verification?.threshold == 0.7)
        #expect(policy.extraction?.grounding?.useVision == true)
        #expect(policy.extraction?.config?.modelOptions?.values["max_tokens"] == .int(4096))
        #expect(policy.embeddings?.properties == true)

        let before = try codec.decode(JSONValue.self, from: data).get()
        let after = try codec.decode(JSONValue.self, from: codec.encode(policy).get()).get()
        #expect(after == before)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try codec.decode(type, from: fixture(name)).get()
    }

    private func fixture(_ name: String) throws -> Data {
        let directory = try #require(ProcessInfo.processInfo.environment["VERTESIA_STUDIO_OPENAPI_FIXTURES"])
        return try Data(contentsOf: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name))
    }

    private func instant(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private func array(_ first: Data, _ second: Data) -> Data {
        Data("[".utf8) + first + Data(",".utf8) + second + Data("]".utf8)
    }
}
