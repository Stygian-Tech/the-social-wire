import Foundation
import Testing
@testable import AppView

@Suite("Publication resolve URL logic")
struct PublicationResolveURLLogicTests {
  @Test("well-known discovery uses the site origin")
  func siteOriginDropsArticlePathAndQuery() throws {
    let input = try #require(URL(string: "https://example.com:8443/articles/one?ref=feed#body"))

    #expect(
      PublicationResolveURLLogic.siteOriginURL(for: input).absoluteString
        == "https://example.com:8443"
    )
  }
}
