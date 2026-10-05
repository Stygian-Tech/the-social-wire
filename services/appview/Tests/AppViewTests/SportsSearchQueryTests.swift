import Foundation
import HummingbirdCore
import SportsCore
import Testing
import WireCore
@testable import AppView

struct SportsSearchQueryTests {
  @Test func browserFormAndPercentEncodedQueriesAgree() throws {
    for (encoded, name) in [("Mount+Union", "Mount Union Football"), ("Mount%20Union", "Mount Union Football"), ("Red+Bull+Racing", "Red Bull Racing"), ("Red%20Bull%20Racing", "Red Bull Racing"), ("Racing+Bulls", "Racing Bulls")] {
      let uri = URI("/xrpc/app.thesocialwire.discovery.searchSportsEntities?q=" + encoded)
      let query = try SportsSearchQuery.decode(uri.query)
      #expect(SportsReviewedCatalog.entities.contains { $0.name == name && $0.name.localizedCaseInsensitiveContains(query) })
    }
    for alias in ["RBR", "VCARB"] {
      let query = try SportsSearchQuery.decode("q=" + alias)
      #expect(SportsReviewedCatalog.entities.contains { $0.aliases.contains(query) })
    }
  }

  @Test func decodingHappensExactlyOnceAndPreservesLiteralPlus() throws {
    #expect(try SportsSearchQuery.decode("q=A%2BB") == "A+B")
    #expect(try SportsSearchQuery.decode("q=A+B") == "A B")
    #expect(try SportsSearchQuery.decode("q=Mount%2520Union") == "Mount%20Union")
    #expect(try SportsSearchQuery.decode("q=%252B") == "%2B")
    #expect(try SportsSearchQuery.decode("lang=en&%71=Mount+Union") == "Mount Union")
    #expect(try SportsSearchQuery.decode("q=Mount+Union&q=Other") == "Mount Union")
    #expect(throws: WireServingError.invalidCursor) { try SportsSearchQuery.decode("q=%ZZ") }
    #expect(throws: WireServingError.invalidCursor) { try SportsSearchQuery.decode("lang=en") }
  }
}
