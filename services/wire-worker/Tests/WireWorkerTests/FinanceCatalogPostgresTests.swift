import FinanceCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import PostgresNIO
import Testing
@testable import WireWorkerCore

private struct FinanceCatalogStubTransport: FinanceHTTPTransport {
  let status: Int
  func data(for request: URLRequest) async throws -> (Data, Int) {
    if request.url?.path == "/v3/mapping", status == 200,
      let body = request.httpBody, let jobs = try JSONSerialization.jsonObject(with: body) as? [[String: String]] {
      let response = jobs.map { job in
        ["data": [["figi": job["idValue"] ?? "", "name": "Fixture Security", "ticker": job["idValue"] ?? ""]]]
      }
      return (try JSONSerialization.data(withJSONObject: response), status)
    }
    if request.url?.host == "api.coingecko.com" { throw FinanceProviderError.invalidRequest }
    return (Data("[]".utf8), status)
  }
}

extension WirePostgresIntegrationTests {
  @Test("Finance catalog publishes atomically and retains the active snapshot during provider outages")
  func financeCatalogAtomicActivationAndOutage() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "finance-catalog-postgres.integration")
    let pool = PostgresClient(configuration: try PostgresWireConfig.make(from: url, logger: logger), backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    defer { runTask.cancel() }
    var previousVersion: String?
    let previous = try await pool.query("SELECT version FROM finance_catalog_snapshots WHERE is_active=TRUE", logger: logger)
    for try await row in previous { previousVersion = try row.decode(String.self) }
    let baselineRows = try await pool.query("SELECT COALESCE(jsonb_agg(to_jsonb(instrument)), '[]'::jsonb)::text FROM finance_instruments instrument", logger: logger)
    var baselineInstruments = "[]"
    for try await row in baselineRows { baselineInstruments = try row.decode(String.self) }
    let asOf = Date().addingTimeInterval(7 * 86_400)
    let settings = ["FINANCE_FEED_MODE": "shadow", "FINANCE_CATALOG_RIGHTS_CONFIRMED": "true", "FINANCE_OPENFIGI_IDS": "BBG000B9Y5X2"]
    let first = PostgresFinanceMaterializer(pool: pool, logger: logger, authority: nil,
      environment: settings, transport: FinanceCatalogStubTransport(status: 200))
    let snapshot = try await first.refreshCatalogIfDue(asOf: asOf)
    #expect(snapshot.instruments.allSatisfy { $0.kind != "crypto" })
    #expect(snapshot.version != previousVersion)
    guard snapshot.version != previousVersion else { return }
    // Search growth must not disable all projection; overrides are bounded while reviewed snapshot coverage remains.
    let namespace = UUID().uuidString.lowercased()
    let extraInstruments = (0..<160).map { index in
      FinanceInstrument(id: "fin_discovery_" + namespace + "_" + String(format: "%03d", index),
        name: "Discovery Fixture", symbol: "D" + String(index), kind: "Common Stock", providerID: "BBG-fixture-" + namespace + "-" + String(index))
    }
    let extras = String(decoding: try JSONEncoder().encode(extraInstruments), as: UTF8.self)
    try await pool.query("""
      INSERT INTO finance_instruments (instrument_id,provider_key,payload,updated_at)
      SELECT instrument->>'id',instrument->>'providerID',instrument, \(asOf)
      FROM jsonb_array_elements(\(extras)::jsonb) instrument
      """, logger: logger)
    let bounded = try #require(try await PostgresFinanceCatalogReader.load(pool: pool, logger: logger))
    #expect(bounded.snapshot.instruments.count <= snapshot.instruments.count + 150)
    #expect(Set(snapshot.instruments.map(\.id)).isSubset(of: Set(bounded.snapshot.instruments.map(\.id))))
    #expect(bounded.snapshot.instruments.filter { $0.id.hasPrefix("fin_discovery_" + namespace) }.count <= 150)
    #expect(bounded.snapshot.instruments.filter { $0.id.hasPrefix("fin_discovery_" + namespace) }.count >= 100)
    let outage = PostgresFinanceMaterializer(pool: pool, logger: logger, authority: nil,
      environment: settings, transport: FinanceCatalogStubTransport(status: 429))
    do {
      let retained = try await outage.refreshCatalogIfDue(asOf: asOf.addingTimeInterval(86_401))
      #expect(retained.version == snapshot.version)
      let active = try await pool.query("SELECT version FROM finance_catalog_snapshots WHERE is_active=TRUE", logger: logger)
      var versions: [String] = []
      for try await row in active { versions.append(try row.decode(String.self)) }
      #expect(versions == [snapshot.version])
    } catch {
      try await cleanupFinanceSnapshot(pool: pool, logger: logger, version: snapshot.version, previousVersion: previousVersion, baselineInstruments: baselineInstruments, fixtureTime: asOf)
      throw error
    }
    try await cleanupFinanceSnapshot(pool: pool, logger: logger, version: snapshot.version, previousVersion: previousVersion, baselineInstruments: baselineInstruments, fixtureTime: asOf)
  }
}

private func cleanupFinanceSnapshot(pool: PostgresClient, logger: Logger, version: String, previousVersion: String?, baselineInstruments: String, fixtureTime: Date) async throws {
  try await pool.withTransaction(logger: logger) { connection in
    try await connection.query("DELETE FROM finance_catalog_snapshots WHERE version=\(version)", logger: logger)
    try await connection.query("""
      DELETE FROM finance_instruments WHERE updated_at=\(fixtureTime)
        AND instrument_id NOT IN (SELECT instrument_id FROM jsonb_to_recordset(\(baselineInstruments)::jsonb)
          AS baseline(instrument_id text))
      """, logger: logger)
    try await connection.query("""
      INSERT INTO finance_instruments (instrument_id,provider_key,payload,updated_at)
      SELECT instrument_id,provider_key,payload,updated_at
      FROM jsonb_to_recordset(\(baselineInstruments)::jsonb)
        AS baseline(instrument_id text,provider_key text,payload jsonb,updated_at timestamptz)
      ON CONFLICT (instrument_id) DO UPDATE SET payload=EXCLUDED.payload,updated_at=EXCLUDED.updated_at
      WHERE finance_instruments.updated_at=\(fixtureTime)
      """, logger: logger)
    if let previousVersion {
      try await connection.query("UPDATE finance_catalog_snapshots SET is_active=TRUE WHERE version=\(previousVersion)", logger: logger)
    }
  }
}
