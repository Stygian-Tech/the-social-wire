import Foundation

struct ATURI: Equatable, Sendable {
    let repo: String
    let collection: String
    let rkey: String

    init?(_ raw: String) {
        guard raw.hasPrefix("at://") else { return nil }
        let rest = raw.dropFirst("at://".count)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3 else { return nil }
        repo = parts[0]
        collection = parts[1]
        rkey = parts[2]
    }
}

func rkey(from uri: String) -> String {
    uri.split(separator: "/").last.map(String.init) ?? uri
}

func normalizeATRepoParam(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func repoAndPublicationFilter(from publicationId: String) -> (repoDid: String, publicationAtUri: String?) {
    if let at = ATURI(publicationId) {
        return (at.repo, publicationId)
    }
    return (publicationId, nil)
}
