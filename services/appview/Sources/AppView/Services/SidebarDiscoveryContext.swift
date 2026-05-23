import Foundation
import GatewayCore

enum SidebarBuildPhase: String, Sendable {
  case full
  case priority
  case folderPublications
}

struct SidebarDiscoveryContext: Sendable {
  let viewerDid: String
  let folders: [PublicationFolderRecord]
  let prefs: [PublicationPrefsRecordDTO]
  let subscribed: [ProjectionDiscoveredRow]
  let myPublications: [ProjectionDiscoveredRow]
  let unfoldered: [ProjectionDiscoveredRow]
  let following: [ProjectionDiscoveredRow]
  let uniqueRows: [ProjectionDiscoveredRow]
  let enrollAuthorDids: [String]
  let prefsByPublicationId: [String: PublicationPrefsRecordDTO]
}
