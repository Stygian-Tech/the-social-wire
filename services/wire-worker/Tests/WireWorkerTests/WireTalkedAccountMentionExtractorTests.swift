import Testing
@testable import WireWorker

@Suite("The Wire talked-account mention extraction")
struct WireTalkedAccountMentionExtractorTests {
  @Test("extracts explicit mentions and quoted record subjects only")
  func extractsSubjects() {
    let record: [String: Any] = [
      "text": "A story about @alice.example",
      "facets": [[
        "features": [[
          "$type": "app.bsky.richtext.facet#mention",
          "did": "did:plc:alice",
        ]]
      ]],
      "embed": [
        "$type": "app.bsky.embed.record",
        "record": ["uri": "at://did:plc:bob/app.bsky.feed.post/one", "cid": "bafy"],
      ],
    ]
    #expect(WireTalkedAccountMentionExtractor.subjects(in: record) == [
      "did:plc:alice", "did:plc:bob",
    ])
  }

  @Test("does not infer un-faceted handles from text")
  func ignoresPlainText() {
    #expect(WireTalkedAccountMentionExtractor.subjects(in: [
      "text": "A story about @alice.example"
    ]).isEmpty)
  }
}
