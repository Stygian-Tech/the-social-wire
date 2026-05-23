import Foundation
import GatewayCore
import ThinAppViewCore

enum BootstrapStreamSelection {
  static func firstUnreadPublicationId(
    myPublications: [SidebarPublicationRow],
    subscribedUnfoldered: [SidebarPublicationRow],
    following: [SidebarPublicationRow],
    unreadCounts: [String: Int]
  ) -> String? {
    for row in myPublications + subscribedUnfoldered + following {
      let count = unreadCounts[row.publicationId] ?? row.unreadCount ?? 0
      if count > 0 {
        return row.publicationId
      }
    }
    return nil
  }

  static func row(
    publicationId: String,
    in response: PublicationSidebarResponse
  ) -> SidebarPublicationRow? {
    for row in response.myPublications
      + response.subscribedUnfoldered
      + response.followingTabPublications
      + response.allPublicationRows
    {
      if row.publicationId == publicationId {
        return row
      }
    }
    return nil
  }

  /// Author DIDs for priority sidebar rows; used for bounded `recentOnly` enroll warmers.
  static func priorityAuthorDids(from response: PublicationSidebarResponse) -> [String] {
    var seen = Set<String>()
    var dids: [String] = []
    for row in response.myPublications
      + response.subscribedUnfoldered
      + response.followingTabPublications
    {
      let authorDid = row.appViewScope.authorDid
      guard ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid(authorDid),
            seen.insert(authorDid).inserted
      else { continue }
      dids.append(authorDid)
    }
    return dids
  }
}
