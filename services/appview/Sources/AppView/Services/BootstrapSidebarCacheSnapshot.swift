import Foundation
import GatewayCore

/// Internal projection version prevents stale-first loads from restoring article rows for podcasts.
struct BootstrapSidebarCacheSnapshot: Codable, Sendable {
  static let currentVersion = 1
  let version: Int
  let priority: PublicationSidebarResponse
  let folderPayload: AppViewBootstrapSidebarFoldersPayload?

  init(priority: PublicationSidebarResponse, folderPayload: AppViewBootstrapSidebarFoldersPayload?) {
    version = Self.currentVersion
    self.priority = priority
    self.folderPayload = folderPayload
  }

  private enum CodingKeys: String, CodingKey { case version, priority, folderPayload }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decodeIfPresent(Int.self, forKey: .version) == Self.currentVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .version, in: values, debugDescription: "Sidebar projection cache requires rebuilding")
    }
    version = Self.currentVersion
    priority = try values.decode(PublicationSidebarResponse.self, forKey: .priority)
    folderPayload = try values.decodeIfPresent(AppViewBootstrapSidebarFoldersPayload.self, forKey: .folderPayload)
  }
}
