import Foundation
import Testing
@testable import SocialWire

@Suite("SocialWireGatewayClient")
@MainActor
struct SocialWireGatewayClientTests {
    @Test("AppViewEnrollResponse decodes indexed count")
    func appViewEnrollResponseDecodesIndexedCount() throws {
        let data = Data("""
        {"indexed": 42}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppViewEnrollResponse.self, from: data)
        #expect(decoded.indexed == 42)
    }

    @Test("PublicationSidebarResponseDTO decodes appViewScope and unread counts")
    func publicationSidebarDecodesScopeAndUnread() throws {
        let data = Data("""
        {
          "viewerDid": "did:plc:viewer",
          "allPublicationRows": [{
            "publicationId": "at://did:plc:author/site.standard.publication/p1",
            "authorDid": "did:plc:author",
            "title": "Pub",
            "discoveredAt": "2026-01-01T00:00:00.000Z",
            "unreadCount": 3,
            "appViewScope": {
              "authorDid": "did:plc:author",
              "publicationAtUri": "at://did:plc:author/site.standard.publication/p1",
              "publicationScopeAtUris": ["at://did:plc:author/com.standard.publication/p1"],
              "publicationSiteUrls": ["https://example.com"]
            }
          }],
          "folderSections": [{
            "folderRkey": "abc",
            "folderUri": "at://did:plc:viewer/app.thesocialwire.folder/abc",
            "publications": []
          }],
          "myPublications": [],
          "subscribedUnfoldered": [],
          "followingTabPublications": [],
          "enrollAuthorDids": ["did:plc:author"],
          "refreshedAt": "2026-01-01T00:00:00.000Z",
          "unreadCountsByPublicationId": {
            "at://did:plc:author/site.standard.publication/p1": 3
          }
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PublicationSidebarResponseDTO.self, from: data)
        #expect(decoded.allPublicationRows.count == 1)
        #expect(decoded.allPublicationRows[0].unreadCount == 3)
        #expect(decoded.folderSections?.count == 1)
        let counts = PublicationProjectionMapping.unreadCountsMap(from: decoded)
        #expect(counts["at://did:plc:author/site.standard.publication/p1"] == 3)
    }

    @Test("unreadCountsMap prefers unreadCountsByPublicationId over embedded row count")
    func unreadCountsMapPrefersRecordMap() throws {
        let data = Data("""
        {
          "viewerDid": "did:plc:viewer",
          "allPublicationRows": [{
            "publicationId": "did:plc:alice",
            "authorDid": "did:plc:alice",
            "title": "Alice",
            "discoveredAt": "2026-01-01T00:00:00.000Z",
            "unreadCount": 4,
            "appViewScope": {
              "authorDid": "did:plc:alice",
              "publicationAtUri": null,
              "publicationScopeAtUris": [],
              "publicationSiteUrls": []
            }
          }],
          "myPublications": [],
          "subscribedUnfoldered": [],
          "followingTabPublications": [],
          "enrollAuthorDids": [],
          "refreshedAt": "2026-01-01T00:00:00.000Z",
          "unreadCountsByPublicationId": { "did:plc:alice": 1 }
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PublicationSidebarResponseDTO.self, from: data)
        let counts = PublicationProjectionMapping.unreadCountsMap(from: decoded)
        #expect(counts["did:plc:alice"] == 1)
    }

    @Test("unreadCountsMap does not resurrect stale embedded counts when record map is empty")
    func unreadCountsMapIgnoresStaleEmbeddedWhenRecordEmpty() throws {
        let data = Data("""
        {
          "viewerDid": "did:plc:viewer",
          "allPublicationRows": [{
            "publicationId": "did:plc:alice",
            "authorDid": "did:plc:alice",
            "title": "Alice",
            "discoveredAt": "2026-01-01T00:00:00.000Z",
            "unreadCount": 2,
            "appViewScope": {
              "authorDid": "did:plc:alice",
              "publicationAtUri": null,
              "publicationScopeAtUris": [],
              "publicationSiteUrls": []
            }
          }],
          "myPublications": [],
          "subscribedUnfoldered": [],
          "followingTabPublications": [],
          "enrollAuthorDids": [],
          "refreshedAt": "2026-01-01T00:00:00.000Z",
          "unreadCountsByPublicationId": {}
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(PublicationSidebarResponseDTO.self, from: data)
        let counts = PublicationProjectionMapping.unreadCountsMap(from: decoded)
        #expect(counts["did:plc:alice"] == nil)
    }

    @Test("AppViewEntryListResponse decodes entries")
    func appViewEntryListResponseDecodesEntries() throws {
        let data = Data("""
        {"entries":[{"entryId":"at://did/site.standard.document/a","title":"A","publishedAt":"2026-01-01T00:00:00.000Z","originalUrl":"https://example.com/a","isRead":true}],"cursor":null}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppViewEntryListResponse.self, from: data)
        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].title == "A")
        #expect(decoded.entries[0].originalUrl == "https://example.com/a")
        #expect(decoded.entries[0].isRead)
    }

    @Test("AppViewEntryDetailDTO decodes flat AppView entry payload")
    func appViewEntryDetailDTODecodesFlatPayload() throws {
        let data = Data("""
        {"entryId":"at://did/site.standard.document/a","title":"A","publishedAt":"2026-01-01T00:00:00.000Z","contentHtml":"<p>Hi</p>","originalUrl":"https://example.com/a","isRead":false}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(AppViewEntryDetailDTO.self, from: data)
        let entry = dto.toEntryDetail()
        #expect(entry.title == "A")
        #expect(entry.contentHtml == "<p>Hi</p>")
        #expect(entry.embedUrl == "https://example.com/a")
    }

    @Test("AppViewUnreadCountsResponse decodes count metadata")
    func appViewUnreadCountsResponseDecodesCounts() throws {
        let data = Data("""
        {"counts":{"at://did/site.standard.publication/p1":2},"generation":42,"accuracy":"exact","countedAt":"2026-01-01T00:00:00.000Z"}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppViewUnreadCountsResponse.self, from: data)
        #expect(decoded.counts?["at://did/site.standard.publication/p1"] == 2)
        #expect(decoded.generation == 42)
        #expect(decoded.accuracy == "exact")
        #expect(decoded.countedAt == "2026-01-01T00:00:00.000Z")
    }

    @Test("GatewayMarkAllReadResponseDTO decodes confirmed boundaries")
    func gatewayMarkAllReadResponseDecodesMarked() throws {
        let data = Data("""
        {
          "marked": 7,
          "confirmedAt": "2026-07-28T20:00:00.000Z",
          "boundaries": [{
            "publicationId": "at://did/site.standard.publication/main",
            "createdAt": "2026-07-28T19:59:00.000Z",
            "entryId": "at://did/site.standard.document/latest"
          }],
          "unreadCounts": {"at://did/site.standard.publication/main": 0}
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(GatewayMarkAllReadResponseDTO.self, from: data)
        #expect(decoded.marked == 7)
        #expect(decoded.boundaries.first?.entryId == "at://did/site.standard.document/latest")
        #expect(decoded.unreadCounts["at://did/site.standard.publication/main"] == 0)
    }
}
