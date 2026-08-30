import Foundation

struct WireViewerModerationSnapshot: Sendable {
  let blockedDIDs: Set<String>
  let mutedDIDs: Set<String>
  let mutedWords: [String]
  let interestTags: Set<String>
  let fetchedAt: Date

  init(
    blockedDIDs: Set<String>,
    mutedDIDs: Set<String>,
    mutedWords: [String],
    interestTags: Set<String> = [],
    fetchedAt: Date
  ) {
    self.blockedDIDs = blockedDIDs
    self.mutedDIDs = mutedDIDs
    self.mutedWords = mutedWords
    self.interestTags = interestTags
    self.fetchedAt = fetchedAt
  }

  func allows(item: String, title: String, summary: String?, representativeURI: String?) -> Bool {
    if let did = Self.subjectDID(item: item, representativeURI: representativeURI),
      blockedDIDs.contains(did) || mutedDIDs.contains(did)
    {
      return false
    }
    let searchable = "\(title) \(summary ?? "")".lowercased()
    return !mutedWords.contains { searchable.contains($0) }
  }

  private static func subjectDID(item: String, representativeURI: String?) -> String? {
    if item.hasPrefix("did:") { return item }
    guard let representativeURI, representativeURI.hasPrefix("at://") else { return nil }
    return representativeURI.dropFirst(5).split(separator: "/").first.map(String.init)
  }
}

actor WireViewerModerationCache {
  private var snapshots: [String: WireViewerModerationSnapshot] = [:]

  func fresh(viewerDID: String, now: Date) -> WireViewerModerationSnapshot? {
    guard let snapshot = snapshots[viewerDID], now.timeIntervalSince(snapshot.fetchedAt) <= 5 * 60
    else { return nil }
    return snapshot
  }

  func usable(viewerDID: String, now: Date) -> WireViewerModerationSnapshot? {
    guard let snapshot = snapshots[viewerDID], now.timeIntervalSince(snapshot.fetchedAt) <= 30 * 60
    else { return nil }
    return snapshot
  }

  func store(_ snapshot: WireViewerModerationSnapshot, viewerDID: String) {
    snapshots[viewerDID] = snapshot
  }
}
