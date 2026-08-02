import Foundation

enum PublicationResolveURLLogic {
  static func siteOriginURL(for url: URL) -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url ?? url
  }
}
