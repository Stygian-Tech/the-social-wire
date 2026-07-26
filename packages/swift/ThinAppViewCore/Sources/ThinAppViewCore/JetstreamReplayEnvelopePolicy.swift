import Foundation

struct JetstreamReplayEnvelopePolicy: Sendable {
  enum CursorDisposition: Equatable, Sendable {
    case missing
    case beforeWindow(Int64)
    case withinWindow(Int64)
    case pastUpperBound(Int64)
  }

  let window: JetstreamReplayWindow
  private let authorDids: Set<String>
  private let collections: Set<String>

  init(
    window: JetstreamReplayWindow,
    authorDids: [String],
    collections: [String]
  ) {
    self.window = window
    self.authorDids = Set(authorDids)
    self.collections = Set(collections)
  }

  func classifyCursor(_ json: [String: Any]) -> CursorDisposition {
    guard let cursor = JetstreamCursor.parse(json["time_us"]) else { return .missing }
    if window.isPastUpperBound(cursor) { return .pastUpperBound(cursor) }
    if !window.contains(cursor) { return .beforeWindow(cursor) }
    return .withinWindow(cursor)
  }

  func includes(did: String, collection: String) -> Bool {
    (authorDids.isEmpty || authorDids.contains(did)) && collections.contains(collection)
  }
}
