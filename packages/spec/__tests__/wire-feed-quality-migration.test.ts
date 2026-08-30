import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const migration = readFileSync(
  join(
    import.meta.dir,
    "../../../database/migrations/20260830033000_harden_wire_feed_quality.sql",
  ),
  "utf8",
);

describe("The Wire feed quality migration", () => {
  it("makes operational status pages non-admissible", () => {
    expect(migration).toContain("'operational_status'");
    expect(migration).toContain("eligible = FALSE");
    expect(migration).toContain("lower(source_domain) ~ '^(status|statuspage)\\.'");
    expect(migration).not.toContain("canonical_url ~ '.*incidents");
  });

  it("rebuilds strict language evidence without trusting share language", () => {
    expect(migration).toContain("latest_standard_record");
    expect(migration).toContain("'{commit,record,lang}'");
    expect(migration).toContain("THEN 'unknown'::text ELSE 'standard_site_record'::text");
    expect(migration).toContain("metadata.language_checked_at IS NOT NULL");
  });
});
