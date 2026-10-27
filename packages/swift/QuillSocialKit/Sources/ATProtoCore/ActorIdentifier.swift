/// Either a DID or a handle, as accepted by `app.bsky.actor.getProfile` and similar endpoints.
public enum ActorIdentifier: Hashable, Codable, Sendable, CustomStringConvertible {
    case did(DID)
    case handle(Handle)

    public init(_ string: String) throws {
        if string.hasPrefix("did:") {
            self = .did(try DID(string))
        } else {
            self = .handle(try Handle(string.hasPrefix("@") ? String(string.dropFirst()) : string))
        }
    }

    public var description: String {
        switch self {
        case let .did(did): did.rawValue
        case let .handle(handle): handle.rawValue
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
