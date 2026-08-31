import Foundation
import Testing
@testable import SocialWire

@Suite("Article social record contracts")
struct ArticleSocialContractTests {
    @Test("Wire feedback normalizes fragments and uses the web-compatible SHA-256 key")
    func wireFeedbackURLAndKey() throws {
        #expect(WireArticleFeedbackContract.normalizeCanonicalURL(
            "https://example.com/story#comments"
        ) == "https://example.com/story")
        #expect(WireArticleFeedbackContract.normalizeCanonicalURL(
            "at://did:plc:test/app.bsky.feed.post/1"
        ) == nil)
        #expect(try WireArticleFeedbackContract.recordKey(
            canonicalURL: "https://example.com/story#comments"
        ) == "ab116c15d8ac8b5285e0a8c70be0bf03ad55f8ca63cbfe0903142381dec8268d")
    }

    @Test("Wire feedback record encodes the published Lexicon shape")
    func wireFeedbackRecordEncoding() throws {
        let record = WireArticleFeedbackRecord(
            type: PDSRecordService.wireArticleFeedback,
            canonicalUrl: "https://example.com/story",
            subject: "at://did:plc:author/site.standard.document/story",
            value: .notGood,
            createdAt: "2026-08-30T12:00:00Z",
            updatedAt: "2026-08-30T12:05:00Z"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: String]
        )

        #expect(object["$type"] == "app.thesocialwire.wireFeedback")
        #expect(object["canonicalUrl"] == "https://example.com/story")
        #expect(object["subject"] == "at://did:plc:author/site.standard.document/story")
        #expect(object["value"] == "not_good")
        #expect(object["createdAt"] == "2026-08-30T12:00:00Z")
        #expect(object["updatedAt"] == "2026-08-30T12:05:00Z")
    }

    @Test("Recommendations accept only normalized site.standard.document AT-URIs")
    func standardSiteDocumentURI() {
        #expect(StandardSiteRecommendationContract.documentURI(
            from: "at://did:plc:author/site.standard.document/article"
        ) == "at://did:plc:author/site.standard.document/article")
        #expect(StandardSiteRecommendationContract.documentURI(
            from: "at%3A%2F%2Fdid%3Aplc%3Aauthor%2Fsite.standard.document%2Farticle"
        ) == "at://did:plc:author/site.standard.document/article")
        #expect(StandardSiteRecommendationContract.documentURI(
            from: "at://did:plc:author/site.standard.entry/article"
        ) == nil)
        #expect(StandardSiteRecommendationContract.documentURI(
            from: "at://did:plc:author/app.bsky.feed.post/article"
        ) == nil)
        #expect(StandardSiteRecommendationContract.documentURI(
            from: "rss:https://example.com"
        ) == nil)
    }

    @Test("Recommendation record and PDS collection constants match web")
    func recommendationRecordEncoding() throws {
        let record = StandardSiteRecommendRecord(
            type: PDSRecordService.standardSiteRecommend,
            document: "at://did:plc:author/site.standard.document/article",
            createdAt: "2026-08-30T12:00:00Z"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: String]
        )

        #expect(PDSRecordService.wireArticleFeedback == "app.thesocialwire.wireFeedback")
        #expect(PDSRecordService.standardSiteRecommend == "site.standard.graph.recommend")
        #expect(object["$type"] == "site.standard.graph.recommend")
        #expect(object["document"] == "at://did:plc:author/site.standard.document/article")
        #expect(object["createdAt"] == "2026-08-30T12:00:00Z")
    }

    @Test("Wire details retain feedback provenance and recommendation eligibility")
    func wireDetailSocialProvenance() {
        let document = "at://did:plc:author/site.standard.document/article"
        let item = WireFeedItem(
            itemId: "story-1",
            canonicalUrl: "https://example.com/story",
            representativeUri: document,
            title: "Story",
            summary: "Summary",
            publishedAt: "2026-08-30T12:00:00Z",
            thumbnailUrl: nil,
            source: WireFeedSource(name: "Example", domain: "example.com"),
            reasons: [],
            provenance: []
        )
        let detail = item.toEntryDetail()

        #expect(detail.wireFeedbackCanonicalUrl == "https://example.com/story")
        #expect(detail.wireFeedbackSubject == document)
        #expect(detail.standardSiteDocumentURI == document)
    }

    @Test("Cached entry details created before social actions remain decodable")
    func legacyEntryDetailDecoding() throws {
        let detail = try JSONDecoder().decode(
            EntryDetail.self,
            from: Data("""
            {
              "entryId": "story-1",
              "title": "Story",
              "publishedAt": "",
              "contentHtml": "<p>Body</p>"
            }
            """.utf8)
        )

        #expect(detail.wireFeedbackCanonicalUrl == nil)
        #expect(detail.wireFeedbackSubject == nil)
    }
}
