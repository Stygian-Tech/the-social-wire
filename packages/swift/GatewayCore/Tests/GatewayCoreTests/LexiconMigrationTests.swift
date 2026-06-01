import Foundation
import Testing

@testable import GatewayCore

@Suite("LexiconMigration")
struct LexiconMigrationTests {
  @Test("legacy collection pairs cover all migrated Social Wire records")
  func legacyCollectionPairs() {
    #expect(PublicationLexicons.legacyCollections.count == 4)
    #expect(PublicationLexicons.legacyCollections.contains { $0.legacy == PublicationLexicons.legacyFolder })
    #expect(PublicationLexicons.legacyCollections.contains { $0.current == PublicationLexicons.folder })
  }
}
