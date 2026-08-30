import Foundation
import WireCore

actor InMemoryCirclePrivateStateStore: CirclePrivateStateStoring {
  private struct SnapshotEntry {
    let exclusionDigest: String
    let snapshot: CircleGraphSnapshot
  }

  private struct EditionKey: Hashable {
    let viewerDID: String
    let snapshotID: UUID
    let generationID: String
    let language: String
  }

  private struct EditionEntry {
    let expiresAt: Date
    let payload: Data
  }

  private var snapshots: [String: SnapshotEntry] = [:]
  private var hides: [String: Set<String>] = [:]
  private var editions: [EditionKey: EditionEntry] = [:]

  func load(viewerDID: String, excludedDIDs: Set<String>) async throws -> CircleGraphSnapshot? {
    guard let entry = snapshots[viewerDID],
      entry.exclusionDigest == Self.exclusionDigest(excludedDIDs)
    else { return nil }
    return entry.snapshot
  }

  func store(_ snapshot: CircleGraphSnapshot, excludedDIDs: Set<String>) async throws {
    snapshots[snapshot.viewerDID] = SnapshotEntry(
      exclusionDigest: Self.exclusionDigest(excludedDIDs),
      snapshot: snapshot
    )
  }

  func hiddenStoryIDs(viewerDID: String) async throws -> Set<String> {
    hides[viewerDID] ?? []
  }

  func setHidden(viewerDID: String, storyID: String, hidden: Bool, now: Date) async throws {
    if hidden {
      hides[viewerDID, default: []].insert(storyID)
    } else {
      hides[viewerDID]?.remove(storyID)
    }
    editions = editions.filter { $0.key.viewerDID != viewerDID }
  }

  func cachedEdition(
    viewerDID: String,
    snapshotID: UUID,
    generationID: String,
    language: String,
    now: Date
  ) async throws -> Data? {
    let key = EditionKey(
      viewerDID: viewerDID,
      snapshotID: snapshotID,
      generationID: generationID,
      language: language
    )
    guard let entry = editions[key], entry.expiresAt > now else { return nil }
    return entry.payload
  }

  func storeEdition(
    viewerDID: String,
    snapshotID: UUID,
    generationID: String,
    language: String,
    expiresAt: Date,
    payload: Data
  ) async throws {
    editions[
      EditionKey(
        viewerDID: viewerDID,
        snapshotID: snapshotID,
        generationID: generationID,
        language: language
      )] = EditionEntry(expiresAt: expiresAt, payload: payload)
  }

  func purge(viewerDID: String) async throws {
    snapshots.removeValue(forKey: viewerDID)
    hides.removeValue(forKey: viewerDID)
    editions = editions.filter { $0.key.viewerDID != viewerDID }
  }

  private static func exclusionDigest(_ excludedDIDs: Set<String>) -> String {
    WireCorpusServiceTrust.bodyDigest(Data(excludedDIDs.sorted().joined(separator: "\n").utf8))
  }
}
