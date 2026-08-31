import Foundation

struct EntryDetail: Identifiable, Codable, Equatable, Sendable {
    var entryId: String
    var title: String
    var publishedAt: String
    var contentHtml: String
    var originalUrl: String?
    var embedUrl: String?
    var bskyPostUri: String?
    var bskyPostCid: String?
    /// Present only for stories opened from The Wire, where quality feedback is applicable.
    var wireFeedbackCanonicalUrl: String? = nil
    /// Optional public AT-URI attached to a Wire feedback record.
    var wireFeedbackSubject: String? = nil

    var id: String { entryId }
    var canonicalURL: URL? {
        guard let raw = embedUrl ?? originalUrl else { return nil }
        return URL(string: PublicURLNormalizer.normalizeHttpURLToHTTPS(raw))
    }

    var standardSiteDocumentURI: String? {
        StandardSiteRecommendationContract.documentURI(from: wireFeedbackSubject)
            ?? StandardSiteRecommendationContract.documentURI(from: entryId)
    }
}
