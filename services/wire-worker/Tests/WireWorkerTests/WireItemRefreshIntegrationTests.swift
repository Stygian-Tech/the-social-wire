import Foundation
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("identical item observations skip row versions and still repair missing metadata")
  func unchangedItemRepairsMetadataWithoutRewrite() async throws {
    try await WireSourceVersionFixture.run { fixture in
      let at = fixture.base.now.addingTimeInterval(60)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.base.apply(sequence: 1, asOf: at) == .applied)
      let itemVersion = try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_items WHERE canonical_key = \(fixture.key)")
      let aliasVersion = try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_item_aliases WHERE alias_key = \(fixture.sourceURI)")
      try await fixture.base.pool.query(
        "DELETE FROM wire_link_metadata_cache WHERE canonical_key = \(fixture.key)",
        logger: fixture.base.logger)
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.base.apply(sequence: 2, asOf: at) == .applied)
      #expect(try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_items WHERE canonical_key = \(fixture.key)") == itemVersion)
      #expect(try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_item_aliases WHERE alias_key = \(fixture.sourceURI)") == aliasVersion)
      #expect(try await fixture.base.scalar(
        "SELECT COUNT(*)::bigint FROM wire_link_metadata_cache WHERE canonical_key = \(fixture.key)") == 1)
      #expect(try await fixture.signalCount() == 0)
    }
  }

  @Test("aliases share hourly expiry while item observation timestamps remain exact")
  func hourlyAliasRefreshPreservesObservations() async throws {
    try await WireSourceVersionFixture.run { fixture in
      let hour = ceil(fixture.base.now.timeIntervalSince1970 / 3_600) * 3_600
      let first = Date(timeIntervalSince1970: hour + 10)
      let second = first.addingTimeInterval(20)
      let nextHour = first.addingTimeInterval(3_600)
      let expiry = WireCacheExpiry.hourlyDeadline(asOf: first, retention: WireDataPolicy.itemRetention)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.base.apply(sequence: 1, asOf: first) == .applied)
      let aliasVersion = try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_item_aliases WHERE alias_key = \(fixture.sourceURI)")
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.base.apply(sequence: 2, asOf: second) == .applied)
      #expect(try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_item_aliases WHERE alias_key = \(fixture.sourceURI)") == aliasVersion)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_items WHERE canonical_key = \(fixture.key)
          AND first_seen_at = \(first) AND last_seen_at = \(second) AND last_signal_at IS NULL
          AND expires_at = \(expiry)
        """) == 1)
      try await fixture.insert(sequence: 3, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.base.apply(sequence: 3, asOf: nextHour) == .applied)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_item_aliases WHERE alias_key = \(fixture.sourceURI)
          AND expires_at = \(expiry.addingTimeInterval(3_600))
        """) == 1)
    }
  }

  @Test("material edits and real publication activity still update within the expiry hour")
  func changedContentAndActivityAreNotSuppressed() async throws {
    try await WireSourceVersionFixture.run { fixture in
      let first = fixture.base.now.addingTimeInterval(60)
      let second = first.addingTimeInterval(1)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.base.apply(sequence: 1, asOf: first) == .applied)
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.newerRevision,
        title: "Updated Article", snapshot: false)
      #expect(try await fixture.base.apply(sequence: 2, asOf: second) == .applied)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_items WHERE canonical_key = \(fixture.key)
          AND title = 'Updated Article' AND last_seen_at = \(second) AND last_signal_at = \(second)
        """) == 1)
      #expect(try await fixture.signalCount() == 1)
      let version = try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_items WHERE canonical_key = \(fixture.key)")
      // Replaying the same fenced commit retains the original activity time.
      try await fixture.insert(sequence: 3, revision: WireSourceVersionFixture.newerRevision,
        title: "Updated Article", snapshot: false)
      #expect(try await fixture.base.apply(sequence: 3, asOf: second) == .applied)
      #expect(try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_items WHERE canonical_key = \(fixture.key)") == version)
      #expect(try await fixture.signalCount() == 1)
    }
  }

  @Test("lower priority content and longer retained expirations are preserved")
  func priorityAndLongerRetentionArePreserved() async throws {
    try await WireSourceVersionFixture.run { fixture in
      let at = fixture.base.now.addingTimeInterval(60)
      let retainedUntil = at.addingTimeInterval(40 * 86_400)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.base.apply(sequence: 1, asOf: at) == .applied)
      try await fixture.base.pool.query(
        """
        UPDATE wire_items SET title = 'Higher Priority Title', eligible = FALSE,
          presentation_snapshot = presentation_snapshot || '{"sourcePriority":500}'::jsonb,
          expires_at = \(retainedUntil)
        WHERE canonical_key = \(fixture.key)
        """, logger: fixture.base.logger)
      try await fixture.base.pool.query(
        "UPDATE wire_item_aliases SET expires_at = \(retainedUntil) WHERE alias_key = \(fixture.sourceURI)",
        logger: fixture.base.logger)
      let version = try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_items WHERE canonical_key = \(fixture.key)")
      let aliasVersion = try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_item_aliases WHERE alias_key = \(fixture.sourceURI)")
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.base.apply(sequence: 2, asOf: at) == .applied)
      #expect(try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_items WHERE canonical_key = \(fixture.key)") == version)
      #expect(try await fixture.base.scalar(
        "SELECT xmin::text::bigint FROM wire_item_aliases WHERE alias_key = \(fixture.sourceURI)") == aliasVersion)
    }
  }

  @Test("alias retargeting still updates without shortening its retained deadline")
  func aliasRetargetingPreservesDeadline() async throws {
    try await WireSourceVersionFixture.run { fixture in
      let at = fixture.base.now.addingTimeInterval(60)
      let retainedUntil = at.addingTimeInterval(40 * 86_400)
      try await fixture.insert(sequence: 1, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.base.apply(sequence: 1, asOf: at) == .applied)
      let other = try await fixture.base.publishSubject("other")
      try await fixture.base.pool.query(
        """
        UPDATE wire_item_aliases SET canonical_key = \(other), expires_at = \(retainedUntil)
        WHERE alias_key = \(fixture.sourceURI)
        """, logger: fixture.base.logger)
      try await fixture.insert(sequence: 2, revision: WireSourceVersionFixture.olderRevision, snapshot: true)
      #expect(try await fixture.base.apply(sequence: 2, asOf: at) == .applied)
      #expect(try await fixture.base.scalar(
        """
        SELECT COUNT(*)::bigint FROM wire_item_aliases WHERE alias_key = \(fixture.sourceURI)
          AND canonical_key = \(fixture.key) AND alias_type = 'at_uri' AND expires_at = \(retainedUntil)
        """) == 1)
    }
  }
}
