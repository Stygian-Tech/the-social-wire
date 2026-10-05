import FinanceCore
import Foundation
import Logging
import PostgresNIO

/// Bounded, rebuildable article analysis on Projection Pool. Never calls providers.
actor PostgresFinanceArticleProjector {
  static let resolverVersion = FinanceResolver.version
  static let batchLimit = 25
  static let scanWindowLimit = 1000
  private var sweepCursor: (date: Date, key: String)?
  private let pool: PostgresClient
  private let logger: Logger
  private let providerPolicy: FinanceCatalogProviderPolicy
  init(pool: PostgresClient, logger: Logger, environment: [String: String] = [:]) {
    self.pool = pool; self.logger = logger; self.providerPolicy = .init(environment: environment)
  }

  func project(asOf: Date) async throws -> Int {
    guard let catalog = try await PostgresFinanceCatalogReader.load(pool: pool, logger: logger, providerPolicy: providerPolicy) else { return 0 }
    var processed = 0
    // The head stays hot while the independent keyset sweep reaches old articles.
    processed += try await projectWindow(asOf: asOf, catalog: catalog, cursor: nil, limit: 12, advancesSweep: false)
    processed += try await projectWindow(asOf: asOf, catalog: catalog, cursor: sweepCursor,
      limit: Self.batchLimit - processed, advancesSweep: true)
    try await pool.query("""
      DELETE FROM finance_article_analysis WHERE canonical_key IN
        (SELECT canonical_key FROM finance_article_analysis WHERE expires_at<=\(asOf) ORDER BY expires_at LIMIT 100)
      """, logger: logger)
    return processed
  }
  private func projectWindow(asOf: Date, catalog: FinanceProjectionCatalog,
    cursor: (date: Date,key: String)?, limit: Int, advancesSweep: Bool) async throws -> Int {
    guard limit > 0 else { return 0 }
    let anchorDate = cursor?.date ?? Date.distantFuture
    let anchorKey = cursor?.key ?? ""
    // Cheap recency traversal uses the partial index before topic/metadata work.
    let window = try await pool.query("""
      SELECT canonical_key,updated_at FROM wire_items
      WHERE eligible=TRUE AND target_kind IN ('external_article','standard_site_document')
        AND commercial_class<>'probable_ad' AND source_confidence>=0.75
        AND updated_at<=\(anchorDate)
        AND (updated_at<\(anchorDate) OR canonical_key>\(anchorKey))
      ORDER BY updated_at DESC,canonical_key LIMIT 1000
      """, logger: logger)
    var keys: [String] = []
    var lastWindow: (date: Date,key: String)?
    for try await row in window {
      let (key,date) = try row.decode((String,Date).self)
      keys.append(key); lastWindow = (date,key)
    }
    guard !keys.isEmpty else {
      if advancesSweep { sweepCursor = nil }
      return 0
    }
    var binds = PostgresBindings()
    binds.append(asOf); binds.append(catalog.revision); binds.append(Self.resolverVersion)
    binds.append(keys); binds.append(limit)
    let rows = try await pool.query(PostgresQuery(unsafeSQL: """
      WITH scan_window AS MATERIALIZED (
        SELECT * FROM wire_items WHERE canonical_key=ANY($4::text[])
      )
      SELECT item.canonical_key,item.title,item.summary,item.source_domain,
        md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text),item.expires_at,item.updated_at
      FROM scan_window item LEFT JOIN finance_article_analysis analysis ON analysis.canonical_key=item.canonical_key
      WHERE \(FinanceCandidateQuality.predicate)
        AND (analysis.canonical_key IS NULL OR analysis.source_fingerprint<>
          md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text)
          OR analysis.catalog_revision<>$2 OR analysis.resolver_version<>$3 OR analysis.expires_at<=$1)
      ORDER BY item.updated_at DESC,item.canonical_key LIMIT $5
      """, binds: binds), logger: logger)
    var lastSelected: (date: Date,key: String)?
    var processed = 0
    for try await row in rows {
      try Task.checkCancellation()
      let (key,title,summary,domain,fingerprint,expiry,updated) = try row.decode((String,String,String?,String,String,Date,Date).self)
      let verified = FinanceReviewedInstrumentMetadata.verifiedInstrumentIDs(domain: domain, account: nil)
      let analysis = FinanceResolver.analyze(title: title, summary: summary,
        verifiedInstrumentIDs: verified, catalog: catalog.snapshot.instruments)
      let payload = String(decoding: try JSONEncoder().encode(analysis), as: UTF8.self)
      // A changed article, catalog, or security override cannot publish stale evidence.
      // Hash the same ordered 150 overrides as PostgresFinanceCatalogReader.
      let accepted = try await pool.query("""
        INSERT INTO finance_article_analysis
          (canonical_key,source_fingerprint,catalog_revision,resolver_version,payload,analyzed_at,expires_at)
        SELECT item.canonical_key,\(fingerprint),\(catalog.revision),\(Self.resolverVersion),\(payload)::jsonb,\(asOf),\(expiry)
        FROM wire_items item WHERE item.canonical_key=\(key) AND item.eligible=TRUE AND item.expires_at>\(asOf)
          AND md5(jsonb_build_array(item.title,item.summary,item.source_domain)::text)=\(fingerprint)
          AND EXISTS (SELECT 1 FROM finance_catalog_snapshots WHERE is_active=TRUE AND version=\(catalog.snapshot.version))
          AND (SELECT md5(COALESCE(jsonb_agg(payload ORDER BY instrument_id),'[]'::jsonb)::text)
            FROM (SELECT instrument_id,payload FROM finance_instruments WHERE provider_key LIKE 'BBG%'
              ORDER BY updated_at DESC,instrument_id LIMIT 150) discovered)=\(catalog.overrideFingerprint)
        ON CONFLICT (canonical_key) DO UPDATE SET source_fingerprint=EXCLUDED.source_fingerprint,
          catalog_revision=EXCLUDED.catalog_revision,resolver_version=EXCLUDED.resolver_version,
          payload=EXCLUDED.payload,analyzed_at=EXCLUDED.analyzed_at,expires_at=EXCLUDED.expires_at
        WHERE finance_article_analysis.analyzed_at<=EXCLUDED.analyzed_at
        RETURNING canonical_key
        """, logger: logger)
      for try await _ in accepted { processed += 1 }
      lastSelected = (updated,key)
    }
    // Commit progress only after every selected write succeeds. A retry cannot skip evidence.
    if advancesSweep { sweepCursor = lastSelected ?? lastWindow }
    return processed
  }

}
