import Foundation
import Testing
@testable import SocialWire

struct BootstrapStreamNDJSONTests {
    @Test func parsesMultipleLines() {
        let json = """
        {"kind":"selectedPublication","selectedPublication":{"publicationId":"pub-a"}}
        {"kind":"done","done":{"refreshedAt":"2026-01-01T00:00:00.000Z"}}
        """
        let events = BootstrapStreamNDJSON.parseLines(json)
        #expect(events.count == 2)
        #expect(events[0].kind == .selectedPublication)
        #expect(events[1].kind == .done)
    }

    @Test func parsesSidebarSectionPayload() {
        let json = """
        {"kind":"sidebarSection","sidebarSection":{"sectionKey":"folder:news","folderRkey":"news","folderUri":"at://did:plc:viewer/app.thesocialwire.folder/news","publications":[],"unreadCounts":{"pub-a":0},"replacePublicationIds":["pub-a"],"refreshedAt":"2026-01-01T00:00:00.000Z","sectionGeneration":42}}
        """
        let events = BootstrapStreamNDJSON.parseLines(json)
        #expect(events.count == 1)
        #expect(events[0].kind == .sidebarSection)
        #expect(events[0].sidebarSection?.sectionKey == "folder:news")
        #expect(events[0].sidebarSection?.unreadCounts?["pub-a"] == 0)
        #expect(events[0].sidebarSection?.replacePublicationIds == ["pub-a"])
        #expect(events[0].sidebarSection?.sectionGeneration == 42)
    }

    @Test func parsesUnreadCountMetadata() {
        let json = """
        {"kind":"unreadCounts","unreadCounts":{"counts":{"pub-a":3},"replacePublicationIds":["pub-a"],"generation":99,"accuracy":"exact","countedAt":"2026-01-01T00:00:00.000Z"}}
        """
        let events = BootstrapStreamNDJSON.parseLines(json)
        #expect(events.count == 1)
        #expect(events[0].kind == .unreadCounts)
        #expect(events[0].unreadCounts?.counts["pub-a"] == 3)
        #expect(events[0].unreadCounts?.generation == 99)
        #expect(events[0].unreadCounts?.accuracy == "exact")
        #expect(events[0].unreadCounts?.countedAt == "2026-01-01T00:00:00.000Z")
    }

    @Test func entriesPageRequiresAndPreservesEvidence() {
        let cached = """
        {"kind":"entriesPage","entriesPage":{"publicationId":"pub-a","entries":[],"source":"projection_cache","cachedAt":"2026-01-01T00:00:00.000Z","expiresAt":"2026-01-01T00:05:00.000Z"}}
        """
        let events = BootstrapStreamNDJSON.parseLines(cached)
        #expect(events.count == 1)
        #expect(events[0].entriesPage?.source == .projectionCache)
        #expect(events[0].entriesPage?.cachedAt == "2026-01-01T00:00:00.000Z")
        #expect(events[0].entriesPage?.expiresAt == "2026-01-01T00:05:00.000Z")

        let ungrounded = """
        {"kind":"entriesPage","entriesPage":{"publicationId":"pub-a","entries":[]}}
        """
        #expect(BootstrapStreamNDJSON.parseLines(ungrounded).isEmpty)
    }

    @Test func firstUnreadUsesPriorityOrder() {
        let subscribed = SidebarPublicationRowDTO(
            publicationId: "pub-sub",
            subscriptionPublicationId: nil,
            authorDid: "did:plc:b",
            authorHandle: nil,
            title: "Sub",
            iconUrl: nil,
            avatarUrl: nil,
            discoveredAt: "2026-01-01T00:00:00.000Z",
            appViewScope: PublicationAppViewScopeDTO(
                authorDid: "did:plc:b",
                publicationAtUri: nil,
                publicationScopeAtUris: [],
                publicationSiteUrls: []
            ),
            unreadCount: 2
        )

        let selected = BootstrapStreamSelection.firstUnreadPublicationId(
            myPublications: [],
            subscribedUnfoldered: [subscribed],
            following: [],
            unreadCounts: ["pub-sub": 2]
        )
        #expect(selected == "pub-sub")
    }
}
