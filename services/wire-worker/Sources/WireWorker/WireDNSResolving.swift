protocol WireDNSResolving: Sendable {
  func validatePublicAddresses(for host: String) async throws
}
