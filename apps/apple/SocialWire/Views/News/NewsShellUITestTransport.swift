#if DEBUG
import Foundation

/// An ephemeral session owns the fixture protocol; no live service request can escape it.
final class NewsShellUITestTransport: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewsShellUITestTransport.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url else { throw URLError(.badURL) }
            let body = try Self.body(for: url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func body(for url: URL) throws -> Data {
        let encoder = JSONEncoder()
        let entity = SportsEntity(id: "fixture-football", name: "Football", kind: "sport",
            sportID: nil, competitionIDs: [], aliases: ["Soccer"], providerIDs: [:], active: true)
        let feed = SportsNamedFeed(id: "fixture-football", title: "Football", kind: "sport",
            entityIDs: [entity.id], description: "Fixture Football Coverage")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        switch url.path {
        case "/xrpc/app.thesocialwire.discovery.getSportsCatalog":
            return try encoder.encode(SportsCatalog(enabled: true, available: true, eventsEnabled: true,
                feeds: [.all, feed], entities: [entity], version: "ui-fixture-v1"))
        case "/xrpc/app.thesocialwire.discovery.getSports":
            let story = WireFeedItem(itemId: "ui-sports-story", canonicalUrl: "https://fixture.example/sports",
                representativeUri: nil, title: "Fixture Football Story", summary: "A deterministic Sports story.",
                publishedAt: "2026-09-02T12:00:00Z", thumbnailUrl: nil,
                source: WireFeedSource(name: "Fixture Sports", domain: "fixture.example"), reasons: [], provenance: [])
            return try encoder.encode(SportsPage(feedId: query["feed"] ?? "sports", eventsEnabled: true,
                items: [SportsFeedItem(story: story, entities: [entity], associations: [], materiality: "reporting", majorGlobal: true)],
                generationId: "ui-sports-generation", generatedAt: "2026-09-02T12:00:00Z",
                expiresAt: "2099-09-02T12:00:00Z", language: query["lang"] ?? "en",
                preferenceRevision: "ui-fixture-v1", cursor: nil, source: "ranked", degraded: false))
        case "/xrpc/app.thesocialwire.discovery.getSportsEvents":
            return try encoder.encode(SportsEventsResponse(events: [SportsEvent(id: "ui-sports-event",
                competitionID: entity.id, entityIDs: [entity.id], title: "Fixture Football Match",
                startsAt: "2099-09-02T12:00:00Z", status: "scheduled", homeName: "Home", awayName: "Away",
                homeScore: nil, awayScore: nil, updatedAt: "2026-09-02T12:00:00Z")],
                updatedAt: "2026-09-02T12:00:00Z", degraded: false))
        default:
            // Unexpected requests fail locally rather than silently reaching a hosted environment.
            throw URLError(.unsupportedURL)
        }
    }
}
#endif
