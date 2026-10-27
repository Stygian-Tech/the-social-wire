/// A decentralized identifier, e.g. `did:plc:ewvi7nxzyoun6zhxrhs64oiz`.
public struct DID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ string: String) throws {
        guard string.count <= 2048,
              string.wholeMatch(of: /did:[a-z]+:[a-zA-Z0-9._:%\-]*[a-zA-Z0-9._\-]/) != nil
        else { throw SyntaxError.invalidDID(string) }
        rawValue = string
    }

    /// The DID method, e.g. `plc` or `web`.
    public var method: Substring {
        rawValue.split(separator: ":", maxSplits: 2)[1]
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
