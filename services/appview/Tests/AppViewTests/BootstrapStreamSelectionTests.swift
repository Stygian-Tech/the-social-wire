import Foundation
import GatewayCore
import Testing
@testable import AppView

struct BootstrapStreamSelectionTests {
  @Test func firstUnreadPrefersPriorityOrder() {
    let my = SidebarPublicationRow(
      publicationId: "pub-my",
      subscriptionPublicationId: nil as String?,
      authorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
      authorHandle: nil as String?,
      title: "Mine",
      iconUrl: nil as String?,
      avatarUrl: nil as String?,
      discoveredAt: Date(),
      appViewScope: PublicationAppViewScope(
        authorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
        publicationAtUri: nil as String?,
        publicationScopeAtUris: [],
        publicationSiteUrls: []
      ),
      unreadCount: 0
    )
    let subscribed = SidebarPublicationRow(
      publicationId: "pub-sub",
      subscriptionPublicationId: nil as String?,
      authorDid: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb",
      authorHandle: nil as String?,
      title: "Sub",
      iconUrl: nil as String?,
      avatarUrl: nil as String?,
      discoveredAt: Date(),
      appViewScope: PublicationAppViewScope(
        authorDid: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb",
        publicationAtUri: nil as String?,
        publicationScopeAtUris: [],
        publicationSiteUrls: []
      ),
      unreadCount: 2
    )

    let selected = BootstrapStreamSelection.firstUnreadPublicationId(
      myPublications: [my],
      subscribedUnfoldered: [subscribed],
      following: [],
      unreadCounts: ["pub-sub": 2]
    )

    #expect(selected == "pub-sub")
  }

  @Test func priorityAuthorDidsDedupesEligibleAuthors() {
    func row(publicationId: String, authorDid: String) -> SidebarPublicationRow {
      SidebarPublicationRow(
        publicationId: publicationId,
        subscriptionPublicationId: nil,
        authorDid: authorDid,
        authorHandle: nil,
        title: publicationId,
        iconUrl: nil,
        avatarUrl: nil,
        discoveredAt: Date(),
        appViewScope: PublicationAppViewScope(
          authorDid: authorDid,
          publicationAtUri: nil,
          publicationScopeAtUris: [],
          publicationSiteUrls: []
        ),
        unreadCount: nil
      )
    }

    let response = PublicationSidebarResponse(
      viewerDid: "did:plc:viewer",
      folders: [],
      publicationPrefs: [],
      folderSections: [],
      allPublicationRows: [],
      myPublications: [
        row(publicationId: "pub-a", authorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa")
      ],
      subscribedUnfoldered: [
        row(publicationId: "pub-b", authorDid: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb"),
        row(publicationId: "pub-c", authorDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"),
      ],
      followingTabPublications: [],
      enrollAuthorDids: [],
      totalUnreadCount: 0,
      refreshedAt: Date()
    )

    let dids = BootstrapStreamSelection.priorityAuthorDids(from: response)
    #expect(dids == [
      "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
      "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb",
    ])
  }
}
