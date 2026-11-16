/// Model options may combine fields from several providers. Decode and encode their
/// JSON object directly so options from newer provider versions keep their values.
public struct ModelOptions: Codable, Hashable, Sendable {
    public var values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}
