import Foundation

struct JetstreamEndpoint: Equatable, Sendable {
  let id: String
  let displayName: String
  let host: String
  let url: String

  init(url: String, index: Int) {
    let host = URLComponents(string: url)?.host ?? "unknown"
    self.id = host == "unknown" ? "jetstream-\(index + 1)" : host
    self.displayName = Self.displayName(host: host, index: index)
    self.host = host
    self.url = url
  }

  private static func displayName(host: String, index: Int) -> String {
    if host.hasPrefix("jetstream1.") { return "Jetstream 1" }
    if host.hasPrefix("jetstream2.") { return "Jetstream 2" }
    return "Jetstream \(index + 1)"
  }
}

struct JetstreamEndpointPool: Sendable {
  let endpoints: [JetstreamEndpoint]
  private(set) var activeIndex = 0

  init(urls: [String]) {
    precondition(!urls.isEmpty)
    endpoints = urls.enumerated().map { JetstreamEndpoint(url: $0.element, index: $0.offset) }
  }

  var active: JetstreamEndpoint { endpoints[activeIndex] }

  mutating func rotateAfterFailure() -> JetstreamEndpoint {
    activeIndex = (activeIndex + 1) % endpoints.count
    return active
  }
}
