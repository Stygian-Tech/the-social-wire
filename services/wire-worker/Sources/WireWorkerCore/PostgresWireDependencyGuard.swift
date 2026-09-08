import Foundation
import Logging
import PostgresNIO

struct PostgresWireDependencyGuard {
  enum Decision { case proceed, pending, superseded(String) }

  static func decision(
    environment: String, sourceURI: String, generation: String, sequence: Int64,
    cid: String?, subject: String?, revision: String?, requiresVerification: Bool,
    on connection: PostgresConnection, asOf: Date, logger: Logger
  ) async throws -> Decision {
    let rows = try await connection.query(
      """
      SELECT status, source_generation, seq, expected_cid, verified_cid, subject_uri,
             verified_subject_uri, observed_repo_rev, valid_until
      FROM wire_recommendation_dependency_recovery
      WHERE environment = \(environment) AND source_uri = \(sourceURI)
      """, logger: logger)
    for try await row in rows {
      let proof = try row.decode((String, String, Int64, String?, String?, String?, String?, String?, Date?).self)
      if ["absent", "changed"].contains(proof.0), cid == proof.3 {
        let exactOriginal = generation == proof.1 && sequence == proof.2
        let observedOlderVersion: Bool
        if let revision, let observed = proof.7,
          PostgresWireStandardRecordFence.validRevision(revision), PostgresWireStandardRecordFence.validRevision(observed)
        { observedOlderVersion = revision <= observed } else { observedOlderVersion = false }
        if exactOriginal || observedOlderVersion { return .superseded("authoritative_record_\(proof.0)") }
      }
      if proof.0 == "verified", let cid, cid == proof.3, cid == proof.4,
        subject == proof.5, subject == proof.6, proof.8.map({ $0 > asOf }) == true
      { return .proceed }
    }
    return requiresVerification ? .pending : .proceed
  }
}
