import Foundation
import SportsCore
import Testing
@testable import WireWorkerCore

@Test func sportsProjectionRevisionTracksTheActivatedSnapshot() {
  let original = SportsProjectionCatalog(snapshot: .init(version: "reviewed:original", generatedAt: .distantPast, entities: []))
  let refreshed = SportsProjectionCatalog(snapshot: .init(version: "reviewed:refreshed", generatedAt: .distantPast, entities: []))
  #expect(original.revision == "reviewed:original")
  #expect(refreshed.revision != original.revision)
}
