import Foundation

/// Arbitrary protocol metadata, encoded directly as a JSON object inside `_meta`.
public struct Metadata: Codable, Sendable, Equatable {
    public var additionalFields: [String: Value]

    public init(additionalFields: [String: Value] = [:]) {
        self.additionalFields = additionalFields
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        additionalFields = try container.decode([String: Value].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(additionalFields)
    }
}
