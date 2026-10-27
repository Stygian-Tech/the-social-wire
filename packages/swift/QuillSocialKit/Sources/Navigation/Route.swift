import ATProtoCore

/// A pushable destination. Routes are values so they can be restored, deep-linked,
/// and opened in a new window on devices that support multiple windows.
public enum Route: Hashable, Codable, Sendable {
    case thread(ATURI)
    case profile(ActorIdentifier)
    case feed(ATURI)
    case list(ATURI)
    case hashtag(String)
    case conversation(id: String)
    case likedBy(ATURI)
    case repostedBy(ATURI)
    case quotes(ATURI)
    case followers(ActorIdentifier)
    case following(ActorIdentifier)
    case labeler(DID)
    case settings
}
