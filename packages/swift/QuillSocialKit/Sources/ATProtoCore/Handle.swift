/// A domain-name handle, e.g. `alice.bsky.social`. Stored normalized to lowercase.
public struct Handle: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Returned by the App View when a handle fails bidirectional verification.
    public static let invalidSentinel = "handle.invalid"

    public let rawValue: String

    public init(_ string: String) throws {
        let pattern = /([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?/
        guard string.utf8.count <= 253, string.wholeMatch(of: pattern) != nil else {
            throw SyntaxError.invalidHandle(string)
        }
        rawValue = string.lowercased()
    }

    public var isInvalidSentinel: Bool { rawValue == Self.invalidSentinel }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
