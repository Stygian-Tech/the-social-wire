/// A repository record key, e.g. a TID or `self`.
public struct RecordKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ string: String) throws {
        guard (1...512).contains(string.count),
              string != ".", string != "..",
              string.wholeMatch(of: /[a-zA-Z0-9_~.:\-]+/) != nil
        else { throw SyntaxError.invalidRecordKey(string) }
        rawValue = string
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
