struct CircleSharer: Codable, Equatable, Sendable {
    let identity: CirclePublicIdentity
    let relationship: String
    let action: String
    let sourceUri: String
    let timestamp: String
}
