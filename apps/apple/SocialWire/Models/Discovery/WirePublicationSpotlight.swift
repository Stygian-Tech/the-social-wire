struct WirePublicationSpotlight: Codable, Equatable, Sendable {
    let id: String
    let publication: WireFeedSource
    let storyIds: [String]
}
