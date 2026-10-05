import Foundation

struct SportsStandingSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: String { competitionID + ":" + season }
    let competitionID: String
    let season: String
    let sourceURL: String
    let status: String
    let updatedAt: String?
    let degraded: Bool
    let rows: [SportsStandingRow]

    var providerURL: URL? {
        guard let url = URL(string: sourceURL), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    var providerName: String {
        let host = providerURL?.host ?? "Unavailable Source"
        return host == "thesportsdb.com" || host.hasSuffix(".thesportsdb.com") ? "TheSportsDB" : host
    }
}
