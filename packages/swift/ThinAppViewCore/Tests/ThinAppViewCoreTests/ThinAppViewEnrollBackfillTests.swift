import Testing
@testable import ThinAppViewCore

@Suite("ThinAppViewEnrollBackfill")
struct ThinAppViewEnrollBackfillTests {
  @Test("accepts repository DIDs and excludes synthetic or malformed author ids")
  func authorEligibility() {
    #expect(
      ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid(
        "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
      )
    )
    #expect(
      ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid(
        "did:web:profiles.thesocialwire.app"
      )
    )
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("did:web:skyreader.rss"))
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("did:plc:alice"))
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid(""))
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("https://example.com"))
  }
}
