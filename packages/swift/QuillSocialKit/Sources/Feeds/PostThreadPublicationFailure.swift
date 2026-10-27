import Foundation

/// Confirmed progress survives a later draft failure, so callers never replay published posts.
public struct PostThreadPublicationFailure: LocalizedError {
    public let publishedCount: Int
    public let rootURI: String?
    public let rootCID: String?
    public let parentURI: String?
    public let parentCID: String?
    /// A dispatched write may have been accepted even when its response was lost.
    public let currentDraftOutcomeUncertain: Bool
    public let underlyingError: any Error

    public init(publishedCount: Int, rootURI: String?, rootCID: String?, parentURI: String?, parentCID: String?,
                currentDraftOutcomeUncertain: Bool, underlyingError: any Error) {
        self.publishedCount = publishedCount
        self.rootURI = rootURI
        self.rootCID = rootCID
        self.parentURI = parentURI
        self.parentCID = parentCID
        self.currentDraftOutcomeUncertain = currentDraftOutcomeUncertain
        self.underlyingError = underlyingError
    }

    public var errorDescription: String? { underlyingError.localizedDescription }
}
