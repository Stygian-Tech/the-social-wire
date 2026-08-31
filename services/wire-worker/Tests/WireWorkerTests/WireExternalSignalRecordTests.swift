import Testing

@testable import WireWorkerCore

@Suite("External Wire signal record normalization")
struct WireExternalSignalRecordTests {
  private let noteURI = "at://did:plc:author/at.margin.note/3abc"
  private let cardURI = "at://did:plc:author/network.cosmik.card/3card"

  @Test("current Margin note motivations retain action and canonical URL target")
  func marginNotes() throws {
    for motivation in [
      "commenting", "highlighting", "bookmarking", "tagging", "describing", "linking",
      "replying", "editing", "questioning", "assessing",
    ] {
      let result = try #require(
        try WireExternalSignalRecordNormalizer.normalize(
          collection: WireExternalSignalCollection.marginNote,
          record: [
            "motivation": motivation,
            "target": ["source": "https://example.com/story?utm_source=margin"],
            "createdAt": "2026-08-29T12:00:00Z",
          ]
        ))
      #expect(result.sourceCollection == "at.margin.note")
      #expect(result.sourceAction == motivation)
      #expect(result.sourceProvenance == "margin")
      #expect(result.aliasesSourceRecord)
      #expect(
        result.action
          == .replaceSignals(
            kind: "recommendation",
            targets: [.url("https://example.com/story?utm_source=margin")]
          ))
    }
  }

  @Test("Margin reply, like, and collection item resolve their root record aliases")
  func marginReferences() throws {
    let ref: [String: Any] = ["uri": noteURI, "cid": "bafyroot"]
    let reply = try #require(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.marginReply,
        record: ["root": ref, "parent": ref, "text": "Reply", "createdAt": "2026-08-29T12:00:00Z"]
      ))
    #expect(reply.sourceAction == "reply")
    #expect(
      reply.action == .replaceSignals(kind: "recommendation", targets: [.reference(noteURI)]))

    let like = try #require(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.marginLike,
        record: ["subject": ref, "createdAt": "2026-08-29T12:00:00Z"]
      ))
    #expect(like.sourceAction == "like")
    #expect(like.action == .replaceSignals(kind: "like", targets: [.reference(noteURI)]))

    let collectionItem = try #require(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.marginCollectionItem,
        record: [
          "collection": [
            "uri": "at://did:plc:author/at.margin.collection/3collection", "cid": "bafyc",
          ],
          "annotation": ref,
          "createdAt": "2026-08-29T12:00:00Z",
        ]
      ))
    #expect(collectionItem.sourceAction == "collection_item")
    #expect(
      collectionItem.action
        == .replaceSignals(kind: "recommendation", targets: [.reference(noteURI)]))
  }

  @Test("Margin reading room reconciles a deduplicated bounded target set")
  func marginReadingRoom() throws {
    let second = "at://did:plc:author/at.margin.note/3def"
    let result = try #require(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.marginReadingRoom,
        record: ["featuredUris": [noteURI, second, noteURI]]
      ))
    #expect(result.sourceAction == "reading_room")
    #expect(!result.aliasesSourceRecord)
    #expect(
      result.action
        == .replaceSignals(
          kind: "recommendation", targets: [.reference(noteURI), .reference(second)]))
  }

  @Test("Semble URL cards trust content URL over the compatibility top-level URL")
  func sembleURLCard() throws {
    let result = try #require(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.sembleCard,
        record: [
          "type": "URL",
          "url": "https://stale.example/compatibility",
          "content": ["url": "https://example.com/authoritative", "title": "Story"],
        ]
      ))
    #expect(result.sourceAction == "card_url")
    #expect(result.sourceProvenance == "semble")
    #expect(
      result.action
        == .replaceSignals(
          kind: "recommendation", targets: [.url("https://example.com/authoritative")]))
  }

  @Test("Semble NOTE cards use direct discussed URL then root card references")
  func sembleNoteCard() throws {
    let direct = try #require(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.sembleCard,
        record: [
          "type": "NOTE", "content": ["url": "https://example.com/discussed"],
          "originalCard": ["uri": cardURI, "cid": "bafycard"],
        ]
      ))
    #expect(direct.sourceAction == "card_note")
    #expect(
      direct.action
        == .replaceSignals(
          kind: "recommendation", targets: [.url("https://example.com/discussed")]))

    let rooted = try #require(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.sembleCard,
        record: ["type": "NOTE", "parent": ["uri": cardURI, "cid": "bafycard"]]
      ))
    #expect(
      rooted.action == .replaceSignals(kind: "recommendation", targets: [.reference(cardURI)]))
  }

  @Test("Semble connections preserve both targets and exact connection action")
  func sembleConnection() throws {
    let result = try #require(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.sembleConnection,
        record: [
          "source": "https://example.com/source",
          "target": cardURI,
          "connectionType": "OPPOSES",
        ]
      ))
    #expect(result.sourceAction == "connection:OPPOSES")
    #expect(!result.aliasesSourceRecord)
    #expect(
      result.action
        == .replaceSignals(
          kind: "recommendation",
          targets: [.url("https://example.com/source"), .reference(cardURI)]
        ))
  }

  @Test("Semble collection link and removal normalize evidence and retraction")
  func sembleCollectionLink() throws {
    let linkURI = "at://did:plc:author/network.cosmik.collectionLink/3link"
    let link = try #require(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.sembleCollectionLink,
        record: [
          "card": ["uri": cardURI, "cid": "bafycard"],
          "collection": [
            "uri": "at://did:plc:author/network.cosmik.collection/3c", "cid": "bafyc",
          ],
          "addedBy": "did:plc:author",
          "addedAt": "2026-08-29T12:00:00Z",
        ]
      ))
    #expect(link.sourceAction == "collection_link")
    #expect(
      link.action == .replaceSignals(kind: "recommendation", targets: [.reference(cardURI)]))

    let removal = try #require(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.sembleCollectionLinkRemoval,
        record: ["collectionLink": ["uri": linkURI, "cid": "bafylink"]]
      ))
    #expect(removal.sourceAction == "collection_link_removal")
    #expect(removal.action == .retractRecord(linkURI))
  }

  @Test("legacy Margin collections and standalone Semble notes are not signals")
  func exclusions() throws {
    #expect(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: "at.margin.annotation",
        record: ["target": ["source": "https://example.com"]]
      ) == nil)
    #expect(
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.sembleCard,
        record: ["type": "NOTE", "content": ["text": "Standalone thought"]]
      ) == nil)
  }

  @Test("malformed external records fail closed")
  func malformedRecords() {
    #expect(throws: WireExternalSignalRecordError.malformed) {
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.marginNote,
        record: [
          "motivation": "bookmarking", "target": ["source": "javascript:alert(1)"],
          "createdAt": "2026-08-29T12:00:00Z",
        ]
      )
    }
    #expect(throws: WireExternalSignalRecordError.malformed) {
      try WireExternalSignalRecordNormalizer.normalize(
        collection: WireExternalSignalCollection.marginReadingRoom,
        record: ["featuredUris": Array(repeating: noteURI, count: 13)]
      )
    }
  }
}
