public struct TimelineFacet: Hashable, Sendable {
    public enum Feature: Hashable, Sendable {
        case mention(did: String)
        case link(uri: String)
        case tag(String)
    }

    public let byteStart: Int
    public let byteEnd: Int
    public let features: [Feature]

    public init(byteStart: Int, byteEnd: Int, features: [Feature]) {
        self.byteStart = byteStart
        self.byteEnd = byteEnd
        self.features = features
    }
}
