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
const languageValidationMigration = readFileSync(
  join(
    import.meta.dir,
    "../../../database/migrations/20260830043000_validate_wire_page_languages.sql",
  ),
  "utf8",
);
const operationalStatusVendorMigration = readFileSync(
  join(
    import.meta.dir,
    "../../../database/migrations/20260830084000_block_wire_status_aggregators.sql",
  ),
  "utf8",
);
const standardSiteLanguageRecoveryMigration = readFileSync(
  join(
    import.meta.dir,
    "../../../database/migrations/20260831033000_recover_wire_standard_site_languages.sql",
  ),
  "utf8",
);

describe("The Wire feed quality migration", () => {
  it("makes operational status pages non-admissible", () => {
    expect(migration).toContain("'operational_status'");
    expect(migration).toContain("eligible = FALSE");
    expect(migration).toContain("lower(source_domain) ~ '^(status|statuspage)\\.'");
    expect(migration).not.toContain("canonical_url ~ '.*incidents");
    expect(operationalStatusVendorMigration).toContain(
      "lower(source_domain) = 'fedilist.com'",
    );
    expect(operationalStatusVendorMigration).toContain(
      "lower(source_domain) LIKE '%.fedilist.com'",
    );
    expect(operationalStatusVendorMigration).toContain("eligible = FALSE");
  });

  it("rebuilds strict language evidence without trusting share language", () => {
    expect(migration).toContain("latest_standard_record");
    expect(migration).toContain("'{commit,record,lang}'");
    expect(migration).toContain("THEN 'unknown'::text ELSE 'standard_site_record'::text");
    expect(migration).toContain("metadata.language_checked_at IS NOT NULL");
  });

  it("keeps page-declared locale evidence only when bounded content corroborates it", () => {
    expect(languageValidationMigration).toContain("language_lexicon");
    expect(languageValidationMigration).toContain("declared_score >= 2");
    expect(languageValidationMigration).toContain("declared_score >= strongest_contradiction");
    expect(languageValidationMigration).toContain("content_validated_page");
    expect(languageValidationMigration).toContain("WHEN declared = 'ja'");
  });

  it("backfills only unknown eligible Standard Site items from validated page evidence", () => {
    expect(standardSiteLanguageRecoveryMigration).toContain("item.eligible = TRUE");
    expect(standardSiteLanguageRecoveryMigration).toContain("item.expires_at > NOW()");
    expect(standardSiteLanguageRecoveryMigration).toContain(
      "item.target_kind = 'standard_site_document'",
    );
    expect(standardSiteLanguageRecoveryMigration).toContain(
      "item.provenance ? 'standard_site'",
    );
    expect(standardSiteLanguageRecoveryMigration).toContain(
      "item.language_code = 'und'",
    );
    expect(standardSiteLanguageRecoveryMigration).toContain(
      "cache.language_checked_at IS NOT NULL",
    );
    expect(standardSiteLanguageRecoveryMigration).toContain(
      "cache.language_code IS NOT NULL",
    );
    expect(standardSiteLanguageRecoveryMigration).toContain(
      "cache.status IN ('fresh', 'stale')",
    );
    expect(standardSiteLanguageRecoveryMigration).toContain(
      "'content_validated_page'",
    );
  });
});
