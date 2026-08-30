import Foundation
import Testing

@testable import AppView

@Suite("Your Circle private state")
struct CirclePrivateStateStoreTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test("isolates hides and cached editions by viewer")
  func isolatesViewerState() async throws {
    let store = InMemoryCirclePrivateStateStore()
    let snapshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000039")!

    try await store.setHidden(viewerDID: "did:plc:a", storyID: "story-1", hidden: true, now: now)
    try await store.storeEdition(
      viewerDID: "did:plc:a",
      snapshotID: snapshotID,
      generationID: "generation-1",
      language: "en",
      expiresAt: now.addingTimeInterval(60),
      payload: Data("viewer-a".utf8)
    )

    #expect(try await store.hiddenStoryIDs(viewerDID: "did:plc:a") == ["story-1"])
    #expect(try await store.hiddenStoryIDs(viewerDID: "did:plc:b").isEmpty)
    #expect(
      try await store.cachedEdition(
        viewerDID: "did:plc:b",
        snapshotID: snapshotID,
        generationID: "generation-1",
        language: "en",
        now: now
      ) == nil)
  }

  @Test("hide, undo, and purge invalidate private viewer state")
  func hideUndoAndPurge() async throws {
    let store = InMemoryCirclePrivateStateStore()
    let viewer = "did:plc:viewer"
    let snapshotID = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!
    let snapshot = CircleGraphSnapshot(
      snapshotID: snapshotID,
      viewerDID: viewer,
      directMembers: [],
      oneHopMembers: [],
      directCandidateCount: 0,
      oneHopCandidateCount: 0,
      generatedAt: now
    )
    try await store.store(snapshot, excludedDIDs: [])
    try await store.storeEdition(
      viewerDID: viewer,
      snapshotID: snapshotID,
      generationID: "generation-1",
      language: "en",
      expiresAt: now.addingTimeInterval(60),
      payload: Data("edition".utf8)
    )

    try await store.setHidden(viewerDID: viewer, storyID: "story-1", hidden: true, now: now)
    #expect(try await store.hiddenStoryIDs(viewerDID: viewer) == ["story-1"])
    #expect(
      try await store.cachedEdition(
        viewerDID: viewer,
        snapshotID: snapshotID,
        generationID: "generation-1",
        language: "en",
        now: now
      ) == nil)

    try await store.setHidden(viewerDID: viewer, storyID: "story-1", hidden: false, now: now)
    #expect(try await store.hiddenStoryIDs(viewerDID: viewer).isEmpty)
    try await store.purge(viewerDID: viewer)
    #expect(try await store.load(viewerDID: viewer, excludedDIDs: []) == nil)
  }

  @Test("snapshot cache is invalidated when moderation exclusions change")
  func bindsSnapshotToExclusions() async throws {
    let store = InMemoryCirclePrivateStateStore()
    let snapshot = CircleGraphSnapshot(
      snapshotID: UUID(),
      viewerDID: "did:plc:viewer",
      directMembers: [],
      oneHopMembers: [],
      directCandidateCount: 0,
      oneHopCandidateCount: 0,
      generatedAt: now
    )
    try await store.store(snapshot, excludedDIDs: ["did:plc:blocked"])

    #expect(
      try await store.load(
        viewerDID: snapshot.viewerDID,
        excludedDIDs: ["did:plc:blocked"]
      ) == snapshot)
    #expect(
      try await store.load(
        viewerDID: snapshot.viewerDID,
        excludedDIDs: ["did:plc:different"]
      ) == nil)
  }
}
