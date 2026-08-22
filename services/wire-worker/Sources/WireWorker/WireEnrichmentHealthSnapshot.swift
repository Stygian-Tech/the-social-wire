struct WireEnrichmentHealthSnapshot: Equatable, Sendable {
  let metadataHitCount: Int
  let metadataStaleCount: Int
  let metadataMissCount: Int
  let metadataFailureCount: Int
  let oldestFailureAgeSeconds: Double
  let peopleEligibleCount: Int
  let peopleFreshCount: Int
}
