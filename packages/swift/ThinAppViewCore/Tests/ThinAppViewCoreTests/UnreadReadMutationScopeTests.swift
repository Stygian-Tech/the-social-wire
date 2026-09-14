import Foundation
import Testing

@testable import ThinAppViewCore

@Suite("Unread mutation scope matching")
struct UnreadReadMutationScopeTests {
  @Test("Indexed candidates match publication semantics across URI and feed aliases")
  func normalizedCandidateMembership() throws {
    let viewer = "did:plc:viewer"
    let author = "did:plc:author"
    let siteURLs = [
      "https://example.com/feed", "https://example.com/feed?format=rss",
      "https://example.com/feed?format=atom", "https://EXAMPLE.com/feed/",
      "https://example.com/another", "http://example.com/feed",
    ]
    var scopes = siteURLs.enumerated().map { index, site in
      AppViewUnreadCounterSupport.publicationScope(
        viewerDid: viewer, publicationId: "publication-\(index)", authorDid: author,
        publicationAtUri: nil, publicationScopeAtUris: [], publicationSiteUrls: [site], sectionKeys: [])
    }
    let publication = "at://did:plc:author/site.standard.publication/main"
    scopes.append(AppViewUnreadCounterSupport.publicationScope(
      viewerDid: viewer, publicationId: publication, authorDid: author,
      publicationAtUri: publication, publicationScopeAtUris: [], publicationSiteUrls: [], sectionKeys: []))
    let encodedPublication = try #require(publication.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed))
    let additionalSites = [
      " https://example.com/feed/ ", "https://example.com/feed#fragment",
      "https://example.com/feed?format=rss#fragment", "https://example.com/feed?other=query",
      "https://unrelated.example/feed", publication, encodedPublication,
    ]
    let candidates = Set(scopes.flatMap(\.scopeKeys) + additionalSites)
    let json = try UnreadReadMutationScope.json(scopes, additionalSites: additionalSites)
    let rows = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    for (position, scope) in scopes.sorted(by: { $0.publicationId < $1.publicationId }).enumerated() {
      let row = rows[position]
      #expect(row["publicationId"] as? String == scope.publicationId)
      #expect(row["position"] as? Int == position)
      let expected = candidates.filter {
        AppViewUnreadCounterSupport.contentMatchesScope(
          authorDid: author, publicationSite: $0, scope: scope)
      }.sorted()
      #expect(row["scopeKeys"] as? [String] == expected)
    }
  }
}
