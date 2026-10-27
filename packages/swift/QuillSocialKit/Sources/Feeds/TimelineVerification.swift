public struct TimelineVerification: Hashable, Sendable, Identifiable {
    public let issuer: String
    public let issuerDisplayName: String?
    public let issuerHandle: String?
    public let uri: String
    public let isValid: Bool

    public var id: String { uri }

    public init(
        issuer: String,
        issuerDisplayName: String? = nil,
        issuerHandle: String? = nil,
        uri: String,
        isValid: Bool
    ) {
        self.issuer = issuer
        self.issuerDisplayName = issuerDisplayName
        self.issuerHandle = issuerHandle
        self.uri = uri
        self.isValid = isValid
    }
}
