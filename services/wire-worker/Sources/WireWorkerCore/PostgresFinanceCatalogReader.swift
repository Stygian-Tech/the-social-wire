import FinanceCore
import Foundation
import Logging
import PostgresNIO

/// Reads committed catalog metadata only; provider calls remain on Coordinator.
enum PostgresFinanceCatalogReader {
  static func load(pool: PostgresClient, logger: Logger, providerPolicy: FinanceCatalogProviderPolicy = .init(environment: [:])) async throws -> FinanceProjectionCatalog? {
    let rows = try await pool.query("""
      WITH discovered AS MATERIALIZED (
        SELECT instrument_id, payload FROM finance_instruments WHERE provider_key LIKE 'BBG%'
        ORDER BY updated_at DESC, instrument_id LIMIT 150
      )
      SELECT snapshot.payload::text,
        (SELECT md5(COALESCE(jsonb_agg(payload ORDER BY instrument_id), '[]'::jsonb)::text)
          FROM discovered),
        (SELECT COALESCE(jsonb_agg(payload ORDER BY instrument_id), '[]'::jsonb)::text
          FROM discovered)
      FROM finance_catalog_snapshots snapshot WHERE is_active = TRUE LIMIT 1
      """, logger: logger)
    for try await row in rows {
      let (payload, fingerprint, overrides) = try row.decode((String, String, String).self)
      let decoder = JSONDecoder()
      let snapshot = try decoder.decode(FinanceCatalogSnapshot.self, from: Data(payload.utf8))
      let discovered = try decoder.decode([FinanceInstrument].self, from: Data(overrides.utf8))
      guard discovered.count <= 150 else { throw FinanceProviderError.invalidResponse }
      var byID = Dictionary(uniqueKeysWithValues: providerPolicy.filter(snapshot.instruments).map { ($0.id, $0) })
      for instrument in providerPolicy.filter(discovered) { byID[instrument.id] = FinanceReviewedInstrumentMetadata.apply(to: instrument) }
      return .init(snapshot: .init(version: snapshot.version, generatedAt: snapshot.generatedAt,
        instruments: byID.values.sorted { $0.id < $1.id }), overrideFingerprint: fingerprint, providerRevision: providerPolicy.revision)
    }
    return nil
  }
}
