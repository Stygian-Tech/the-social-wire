/// An `at://` URI referencing a repository, collection, or record.
public struct ATURI: Hashable, Codable, Sendable, CustomStringConvertible {
    public let authority: ActorIdentifier
    public let collection: NSID?
    public let recordKey: RecordKey?

    public init(authority: ActorIdentifier, collection: NSID? = nil, recordKey: RecordKey? = nil) {
        self.authority = authority
        self.collection = collection
        self.recordKey = collection == nil ? nil : recordKey
    }

    public init(_ string: String) throws {
        guard string.hasPrefix("at://"), string.utf8.count <= 8192 else {
            throw SyntaxError.invalidATURI(string)
        }
        var body = string.dropFirst(5)
        if let fragment = body.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            body = body[..<fragment]
        }
        let parts = body.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), !parts.contains(where: \.isEmpty) else {
            throw SyntaxError.invalidATURI(string)
        }
        do {
            authority = try ActorIdentifier(String(parts[0]))
            collection = parts.count > 1 ? try NSID(String(parts[1])) : nil
            recordKey = parts.count > 2 ? try RecordKey(String(parts[2])) : nil
        } catch {
            throw SyntaxError.invalidATURI(string)
        }
    }

    public var description: String {
        var result = "at://\(authority)"
        if let collection { result += "/\(collection)" }
        if let recordKey { result += "/\(recordKey)" }
        return result
    }

    public init(from decoder: any Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
