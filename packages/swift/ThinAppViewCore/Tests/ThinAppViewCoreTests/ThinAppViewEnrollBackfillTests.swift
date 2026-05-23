import Testing
@testable import ThinAppViewCore

@Suite("ThinAppViewEnrollBackfill")
struct ThinAppViewEnrollBackfillTests {
  @Test("skips web and non-DID author ids")
  func authorEligibility() {
    #expect(ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("did:plc:alice"))
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("did:web:skyreader.rss"))
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid(""))
    #expect(!ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid("https://example.com"))
  }
}
