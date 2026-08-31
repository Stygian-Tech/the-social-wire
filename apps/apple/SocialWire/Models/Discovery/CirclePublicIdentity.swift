struct CirclePublicIdentity: Codable, Equatable, Sendable {
    let did: String
    let handle: String
    let displayName: String?
    let avatarUrl: String?
}
