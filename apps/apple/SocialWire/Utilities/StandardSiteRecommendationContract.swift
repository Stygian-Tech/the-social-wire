import Foundation

enum StandardSiteRecommendationContract {
    static func documentURI(from value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizeATRepoParam(value)
        guard let parsed = ATURI(normalized),
              parsed.collection == "site.standard.document"
        else { return nil }
        return normalized
    }
}
