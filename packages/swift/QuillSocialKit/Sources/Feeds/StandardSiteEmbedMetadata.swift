import Foundation

public struct StandardSiteEmbedMetadata: Hashable, Sendable {
    public let publicationName: String
    public let publicationURL: URL
    public let publicationURI: String
    public let documentURI: String
    public let logoURL: URL?
    public let authorName: String?
    public let authorAvatarURL: URL?
    public let viewerSubscriptionURI: String?
    public let viewerRecommendURI: String?

    public init(
        publicationName: String,
        publicationURL: URL,
        publicationURI: String,
        documentURI: String = "",
        logoURL: URL?,
        authorName: String?,
        authorAvatarURL: URL?,
        viewerSubscriptionURI: String? = nil,
        viewerRecommendURI: String? = nil
    ) {
        self.publicationName = publicationName
        self.publicationURL = publicationURL
        self.publicationURI = publicationURI
        self.documentURI = documentURI
        self.logoURL = logoURL
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.viewerSubscriptionURI = viewerSubscriptionURI
        self.viewerRecommendURI = viewerRecommendURI
    }

    public func attachingViewerSubscription(_ uri: String?) -> Self {
        Self(
            publicationName: publicationName,
            publicationURL: publicationURL,
            publicationURI: publicationURI,
            documentURI: documentURI,
            logoURL: logoURL,
            authorName: authorName,
            authorAvatarURL: authorAvatarURL,
            viewerSubscriptionURI: uri,
            viewerRecommendURI: viewerRecommendURI
        )
    }

    public func attachingViewerRecommend(_ uri: String?) -> Self {
        Self(
            publicationName: publicationName,
            publicationURL: publicationURL,
            publicationURI: publicationURI,
            documentURI: documentURI,
            logoURL: logoURL,
            authorName: authorName,
            authorAvatarURL: authorAvatarURL,
            viewerSubscriptionURI: viewerSubscriptionURI,
            viewerRecommendURI: uri
        )
    }
}
