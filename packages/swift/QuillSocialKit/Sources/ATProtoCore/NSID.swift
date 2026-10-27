/// A namespaced identifier, e.g. `app.bsky.feed.post`.
public struct NSID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ string: String) throws {
        let pattern = /[a-zA-Z]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+\.[a-zA-Z][a-zA-Z0-9]{0,62}/
        guard string.utf8.count <= 317, string.wholeMatch(of: pattern) != nil else {
            throw SyntaxError.invalidNSID(string)
        }
        rawValue = string
    }

    /// The final segment, e.g. `post` for `app.bsky.feed.post`.
    public var name: Substring {
        rawValue[rawValue.index(after: rawValue.lastIndex(of: ".")!)...]
    }

    /// The reversed-domain authority, e.g. `app.bsky.feed`.
    public var authority: Substring {
        rawValue[..<rawValue.lastIndex(of: ".")!]
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
