public struct TimelineLabel: Hashable, Sendable, Identifiable {
    public var id: String { source + ":" + value }

    public let source: String
    public let value: String
    public let isNegation: Bool

    public init(source: String, value: String, isNegation: Bool = false) {
        self.source = source
        self.value = value
        self.isNegation = isNegation
    }
}
