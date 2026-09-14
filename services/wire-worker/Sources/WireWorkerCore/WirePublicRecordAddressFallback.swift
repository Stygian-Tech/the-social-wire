import Foundation

/// Every candidate is classified before any request starts. Each attempt remains
/// pinned to its classified address, and one deadline covers the entire fallback.
enum WirePublicRecordAddressFallback {
  enum Failure: Error { case connection }

  static func candidates(_ addresses: [String]) throws -> [String] {
    guard !addresses.isEmpty else { throw WirePublicRecordQueryError.unavailable }
    guard addresses.allSatisfy(WirePublicDNSResolver.isPublicAddress) else {
      throw WirePublicRecordQueryError.unsafeEndpoint
    }
    let ordered = Set(addresses).sorted { left, right in
      let leftIPv4 = !left.contains(":")
      let rightIPv4 = !right.contains(":")
      return leftIPv4 == rightIPv4 ? left < right : leftIPv4
    }
    return Array(ordered.prefix(2))
  }

  static func run(
    addresses: [String], timeout: Duration = .seconds(10),
    request: @escaping @Sendable (String) async throws -> WirePublicRecordHTTPResponse
  ) async throws -> WirePublicRecordHTTPResponse {
    try Task.checkCancellation()
    let addresses = try candidates(addresses)
    return try await withThrowingTaskGroup(of: WirePublicRecordHTTPResponse.self) { group in
      group.addTask {
        for address in addresses {
          try Task.checkCancellation()
          do { return try await request(address) }
          catch Failure.connection { try Task.checkCancellation() }
        }
        throw WirePublicRecordQueryError.unavailable
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WirePublicRecordQueryError.unavailable
      }
      defer { group.cancelAll() }
      guard let response = try await group.next() else { throw CancellationError() }
      return response
    }
  }
}
