import Foundation
import SportsCore
import Testing

struct SportsEventPreferenceMembershipTests {
  @Test func transfersUseEventDateAndNeverInferMissingTeams() {
    let transfer = Date(timeIntervalSince1970: 1000)
    let catalog = [SportsEntity(id: "old", name: "Old", kind: "team"), SportsEntity(id: "new", name: "New", kind: "team"), SportsEntity(id: "retired", name: "Retired", kind: "team", active: false), SportsEntity(id: "person", name: "Person", kind: "athlete", memberships: [.init(entityID: "old", validFrom: transfer.addingTimeInterval(-500), validUntil: transfer), .init(entityID: "new", validFrom: transfer), .init(entityID: "retired", validFrom: transfer), .init(entityID: "unknown", validFrom: transfer)])]
    let memberships = SportsEventPreferenceMembership.bindings(preferredIDs: ["person"], catalog: catalog)
    #expect(memberships.filter { $0.includes(transfer.addingTimeInterval(-1)) }.map(\.entityID) == ["old"])
    #expect(memberships.filter { $0.includes(transfer) }.map(\.entityID) == ["new"])
    #expect(SportsEventPreferenceMembership.bindings(preferredIDs: ["old"], catalog: catalog).isEmpty)
  }
}
