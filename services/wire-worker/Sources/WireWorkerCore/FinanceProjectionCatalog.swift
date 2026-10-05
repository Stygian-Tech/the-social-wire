import FinanceCore

struct FinanceProjectionCatalog: Sendable {
  let snapshot: FinanceCatalogSnapshot
  let overrideFingerprint: String
  var providerRevision = "providers-reference-v1"
  var revision: String { snapshot.version + ":" + overrideFingerprint + ":" + FinanceReviewedInstrumentMetadata.version + ":" + providerRevision }
}
