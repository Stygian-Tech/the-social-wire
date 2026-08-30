import Foundation

enum WireExternalSignalCollection {
  static let marginNote = "at.margin.note"
  static let marginReply = "at.margin.reply"
  static let marginLike = "at.margin.like"
  static let marginCollectionItem = "at.margin.collectionItem"
  static let marginReadingRoom = "at.margin.readingRoom"
  static let sembleCard = "network.cosmik.card"
  static let sembleConnection = "network.cosmik.connection"
  static let sembleCollectionLink = "network.cosmik.collectionLink"
  static let sembleCollectionLinkRemoval = "network.cosmik.collectionLinkRemoval"

  static let supported: Set<String> = [
    marginNote, marginReply, marginLike, marginCollectionItem, marginReadingRoom,
    sembleCard, sembleConnection, sembleCollectionLink, sembleCollectionLinkRemoval,
  ]
}

enum WireExternalSignalTarget: Equatable, Sendable {
  case url(String)
  case reference(String)

  var value: String {
    switch self {
    case .url(let value), .reference(let value): value
    }
  }
}

struct WireExternalSignalRecord: Equatable, Sendable {
  enum Action: Equatable, Sendable {
    case replaceSignals(kind: String, targets: [WireExternalSignalTarget])
    case retractRecord(String)
  }

  let action: Action
  let aliasesSourceRecord: Bool
  let sourceCollection: String
  let sourceAction: String
  let sourceProvenance: String
}

enum WireExternalSignalRecordError: Error, Equatable {
  case malformed
}

enum WireExternalSignalRecordNormalizer {
  private static let marginMotivations: Set<String> = [
    "commenting", "highlighting", "bookmarking", "tagging", "describing", "linking",
    "replying", "editing", "questioning", "assessing",
  ]

  static func normalize(
    collection: String,
    record: [String: Any]
  ) throws -> WireExternalSignalRecord? {
    switch collection {
    case WireExternalSignalCollection.marginNote:
      guard
        let motivation = nonemptyString(record["motivation"]),
        marginMotivations.contains(motivation),
        nonemptyString(record["createdAt"]) != nil,
        let target = record["target"] as? [String: Any],
        let source = httpURL(target["source"])
      else { throw WireExternalSignalRecordError.malformed }
      return signals(
        collection: collection, action: motivation, provenance: "margin",
        kind: "recommendation", targets: [.url(source)], aliasesSourceRecord: true)

    case WireExternalSignalCollection.marginReply:
      guard
        nonemptyString(record["createdAt"]) != nil,
        strongReferenceURI(record["parent"]) != nil,
        let root = strongReferenceURI(record["root"])
      else { throw WireExternalSignalRecordError.malformed }
      return signals(
        collection: collection, action: "reply", provenance: "margin",
        kind: "recommendation", targets: [.reference(root)], aliasesSourceRecord: true)

    case WireExternalSignalCollection.marginLike:
      guard
        nonemptyString(record["createdAt"]) != nil,
        let subject = strongReferenceURI(record["subject"])
      else { throw WireExternalSignalRecordError.malformed }
      return signals(
        collection: collection, action: "like", provenance: "margin",
        kind: "like", targets: [.reference(subject)], aliasesSourceRecord: true)

    case WireExternalSignalCollection.marginCollectionItem:
      guard
        nonemptyString(record["createdAt"]) != nil,
        strongReferenceURI(record["collection"]) != nil,
        let annotation = strongReferenceURI(record["annotation"])
      else { throw WireExternalSignalRecordError.malformed }
      return signals(
        collection: collection, action: "collection_item", provenance: "margin",
        kind: "recommendation", targets: [.reference(annotation)], aliasesSourceRecord: true)

    case WireExternalSignalCollection.marginReadingRoom:
      guard let featured = record["featuredUris"] as? [Any], featured.count <= 12 else {
        throw WireExternalSignalRecordError.malformed
      }
      let references = try featured.map { value -> WireExternalSignalTarget in
        guard let uri = atURI(value) else { throw WireExternalSignalRecordError.malformed }
        return .reference(uri)
      }
      return signals(
        collection: collection, action: "reading_room", provenance: "margin",
        kind: "recommendation", targets: references, aliasesSourceRecord: false)

    case WireExternalSignalCollection.sembleCard:
      guard let type = nonemptyString(record["type"])?.uppercased() else {
        throw WireExternalSignalRecordError.malformed
      }
      switch type {
      case "URL":
        guard
          let content = record["content"] as? [String: Any],
          let authoritativeURL = httpURL(content["url"])
        else { throw WireExternalSignalRecordError.malformed }
        return signals(
          collection: collection, action: "card_url", provenance: "semble",
          kind: "recommendation", targets: [.url(authoritativeURL)], aliasesSourceRecord: true)
      case "NOTE":
        if let content = record["content"] as? [String: Any],
          let discussedURL = httpURL(content["url"])
        {
          return signals(
            collection: collection, action: "card_note", provenance: "semble",
            kind: "recommendation", targets: [.url(discussedURL)], aliasesSourceRecord: true)
        }
        guard
          let reference = strongReferenceURI(record["originalCard"])
            ?? strongReferenceURI(record["parent"])
        else { return nil }
        return signals(
          collection: collection, action: "card_note", provenance: "semble",
          kind: "recommendation", targets: [.reference(reference)], aliasesSourceRecord: true)
      default:
        return nil
      }

    case WireExternalSignalCollection.sembleConnection:
      guard
        let source = entityTarget(record["source"]),
        let target = entityTarget(record["target"])
      else { throw WireExternalSignalRecordError.malformed }
      return signals(
        collection: collection,
        action: "connection:\(nonemptyString(record["connectionType"]) ?? "unspecified")",
        provenance: "semble",
        kind: "recommendation", targets: [source, target], aliasesSourceRecord: false)

    case WireExternalSignalCollection.sembleCollectionLink:
      guard
        strongReferenceURI(record["collection"]) != nil,
        let card = strongReferenceURI(record["card"]),
        nonemptyString(record["addedBy"]) != nil,
        nonemptyString(record["addedAt"]) != nil
      else { throw WireExternalSignalRecordError.malformed }
      return signals(
        collection: collection, action: "collection_link", provenance: "semble",
        kind: "recommendation", targets: [.reference(card)], aliasesSourceRecord: true)

    case WireExternalSignalCollection.sembleCollectionLinkRemoval:
      guard
        let link = strongReferenceURI(record["collectionLink"])
          ?? strongReferenceURI(record["link"])
          ?? strongReferenceURI(record["subject"])
      else { throw WireExternalSignalRecordError.malformed }
      return WireExternalSignalRecord(
        action: .retractRecord(link),
        aliasesSourceRecord: false,
        sourceCollection: collection,
        sourceAction: "collection_link_removal",
        sourceProvenance: "semble"
      )

    default:
      return nil
    }
  }

  private static func signals(
    collection: String,
    action: String,
    provenance: String,
    kind: String,
    targets: [WireExternalSignalTarget],
    aliasesSourceRecord: Bool
  ) -> WireExternalSignalRecord {
    var seen: Set<String> = []
    let uniqueTargets = targets.filter { seen.insert($0.value).inserted }
    return WireExternalSignalRecord(
      action: .replaceSignals(kind: kind, targets: uniqueTargets),
      aliasesSourceRecord: aliasesSourceRecord && uniqueTargets.count == 1,
      sourceCollection: collection,
      sourceAction: action,
      sourceProvenance: provenance
    )
  }

  private static func entityTarget(_ value: Any?) -> WireExternalSignalTarget? {
    if let url = httpURL(value) { return .url(url) }
    if let reference = atURI(value) { return .reference(reference) }
    return nil
  }

  private static func strongReferenceURI(_ value: Any?) -> String? {
    if let dictionary = value as? [String: Any] { return atURI(dictionary["uri"]) }
    return atURI(value)
  }

  private static func atURI(_ value: Any?) -> String? {
    guard let value = nonemptyString(value), value.hasPrefix("at://") else { return nil }
    return value
  }

  private static func httpURL(_ value: Any?) -> String? {
    guard let value = nonemptyString(value), let url = URL(string: value), url.host != nil,
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else { return nil }
    return value
  }

  private static func nonemptyString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
