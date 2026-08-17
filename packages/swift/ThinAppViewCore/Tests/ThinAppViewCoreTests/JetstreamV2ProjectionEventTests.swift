import Foundation
import Testing
@testable import ThinAppViewCore

@Suite("Jetstream V2 projection events")
struct JetstreamV2ProjectionEventTests {
  @Test("parses the official Go SDK v0.2.0 JSON representation")
  func parsesOfficialGoSDKFixture() throws {
    let url = try #require(
      Bundle.module.url(
        forResource: "jetstream-v2-go-sdk-v0.2.0-events",
        withExtension: "json",
        subdirectory: "Fixtures"
      )
    )
    let objects = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
    )
    let events = try objects.enumerated().map { index, object in
      try JetstreamV2ProjectionEventParser.parse(
        JSONSerialization.data(withJSONObject: object),
        expectedSequence: Int64(101 + index),
        expectedKind: [.commit, .identity, .account, .sync][index],
        expectedRepoDid: [
          "did:plc:commit", "did:plc:identity", "did:plc:account", "did:plc:sync",
        ][index]
      )
    }

    guard case .commit(let commit) = events[0] else {
      Issue.record("Expected commit fixture")
      return
    }
    #expect(commit.collection == "site.standard.entry")
    let recordJSON = try #require(commit.recordJSON)
    let record = try #require(
      JSONSerialization.jsonObject(with: recordJSON) as? [String: String]
    )
    #expect(record["title"] == "Fixture")
    guard case .identity(let identity) = events[1] else {
      Issue.record("Expected identity fixture")
      return
    }
    #expect(identity.handle == "identity.example")
    guard case .account(let account) = events[2] else {
      Issue.record("Expected account fixture")
      return
    }
    #expect(account.status == .deleted)
    guard case .sync(let sync) = events[3] else {
      Issue.record("Expected sync fixture")
      return
    }
    #expect(sync.repoRev == "3ksync")
  }

  @Test("rejects normalized metadata that does not match the durable row")
  func rejectsMetadataMismatch() throws {
    let payload = Data(
      """
      {"did":"did:plc:one","cursor":77,"time_us":1700000000000000,"kind":"sync",\
      "sync":{"did":"did:plc:one","rev":"3kone","seq":9,"time":"2026-08-15T12:00:00Z"}}
      """.utf8
    )
    #expect(throws: JetstreamV2ProjectionEventParseError.metadataMismatch) {
      try JetstreamV2ProjectionEventParser.parse(
        payload,
        expectedSequence: 78,
        expectedKind: .sync,
        expectedRepoDid: "did:plc:one"
      )
    }
  }

  @Test("configuration keeps V1 authoritative unless the V2 mode is explicit")
  func modeConfigurationIsFailClosed() {
    let defaults = ThinAppViewConfig.fromEnvironment([:])
    #expect(defaults.jetstreamMode == .v1Authoritative)
    #expect(defaults.repositoryRestoreTimeoutSeconds == 120)
    #expect(defaults.jetstreamLeaderLeaseName == "jetstream-v2-ingest")
    let shadow = ThinAppViewConfig.fromEnvironment([
      "THIN_APPVIEW_JETSTREAM_MODE": "v2_shadow",
      "JETSTREAM_SOURCE_GENERATION": "west-filter-v2",
      "JETSTREAM_LEADER_LEASE_NAME": "custom-v2-intake",
    ])
    #expect(shadow.jetstreamMode == .v2Shadow)
    #expect(shadow.jetstreamV2SourceGeneration == "west-filter-v2")
    #expect(shadow.jetstreamLeaderLeaseName == "custom-v2-intake")
    #expect(shadow.jetstreamMode.runsLegacySubscriber)
    let boundedRestore = ThinAppViewConfig.fromEnvironment([
      "THIN_APPVIEW_REPOSITORY_RESTORE_TIMEOUT_SECONDS": "45"
    ])
    #expect(boundedRestore.repositoryRestoreTimeoutSeconds == 45)
    let authoritative = ThinAppViewConfig.fromEnvironment([
      "THIN_APPVIEW_JETSTREAM_MODE": "v2_authoritative"
    ])
    #expect(authoritative.jetstreamMode.drainsV2Inbox)
    #expect(!authoritative.jetstreamMode.runsLegacySubscriber)
    #expect(!authoritative.jetstreamMode.runsLegacyProactiveBackfill)
    #expect(shadow.jetstreamMode.runsLegacyProactiveBackfill)
  }
}
