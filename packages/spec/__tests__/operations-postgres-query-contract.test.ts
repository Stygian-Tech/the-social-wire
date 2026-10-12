import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repositoryRoot = join(import.meta.dir, "../../..");
const readSource = (path: string) => readFileSync(join(repositoryRoot, path), "utf8");
const operationsSource = (file: string) => readSource(`packages/go/operationsapi/${file}.go`);

function storeMethod(file: string, method: string): string {
  const source = operationsSource(file);
  const start = source.indexOf(`func (s *PostgresStore) ${method}(`);
  if (start < 0) throw new Error(`Missing Operations store method: ${method}`);
  const end = source.indexOf("\nfunc ", start + 1);
  return source.slice(start, end < 0 ? source.length : end);
}

const paginatedReads = [
  { file: "durability_store", method: "ListIngestionIncidents", dateColumn: "last_detected_at", dateParameter: 2, idParameter: 3 },
  { file: "endpoint_store", method: "ListJetstreamEndpoints", dateColumn: "updated_at", dateParameter: 2, idParameter: 3 },
  { file: "command_store", method: "ListCommands", dateColumn: "created_at", dateParameter: 2, idParameter: 3 },
  { file: "gap", method: "ListGaps", dateColumn: "detected_at", dateParameter: 3, idParameter: 4 },
  { file: "backfill_store", method: "ListBackfills", dateColumn: "created_at", dateParameter: 3, idParameter: 4 },
  { file: "alert_store", method: "ListAlerts", dateColumn: "opened_at", dateParameter: 3, idParameter: 4 },
  { file: "telemetry_read_store", method: "ListTraceSpansPage", dateColumn: "started_at", dateParameter: 4, idParameter: 5 },
];

describe("Operations Postgres query contracts", () => {
  for (const { file, method, dateColumn, dateParameter, idParameter } of paginatedReads) {
    it(`${method} supports an absent cursor and stable descending continuation`, () => {
      const source = storeMethod(file, method);
      const sql = source.replaceAll(/\s+/g, " ");
      const date = `$${dateParameter}::timestamptz`;
      const id = `$${idParameter}::text`;
      expect(source).toContain("if before != nil");
      expect(source).toContain("DecodePaginationCursor(*before)");
      expect(sql).toContain(`${date} IS NULL OR ${dateColumn}<${date}`);
      expect(sql).toContain(`${dateColumn}=${date} AND id<${id}`);
      expect(sql).toContain(`ORDER BY ${dateColumn} DESC,id DESC LIMIT`);
      expect(source).toContain("limit+1");
      expect(source).toContain("EncodePaginationCursor(");
      expect(source).toContain("page.NextCursor = &cursor");
      expect(source).not.toMatch(/\$\d+ IS NULL/);
    });
  }

  it("keeps optional metric and collection filters typed and environment-scoped", () => {
    const source = storeMethod("telemetry_read_store", "ListMetricRollups");
    expect(source).toContain("WHERE environment=$1 AND bucket_start>=$2 AND bucket_start<=$3");
    expect(source).toContain("($4::text IS NULL OR metric_name=$4::text)");
    expect(source).toContain("($5::text IS NULL OR dimensions->>'collection'=$5::text)");
    expect(source).toContain("s.Environment, start, end, metric, collection,");
    expect(source).toContain("max(1, min(limit, 10000))");
    expect(source).not.toMatch(/\$\d+ IS NULL/);
  });

  it("calls the bounded integer retention signature and preserves pending canonical work", () => {
    const source = storeMethod("retention_store", "CleanupExpired");
    const migration = readSource("database/migrations/20260926190000_bound_operations_change_event_retention.sql");
    expect(source).toContain("batchSize = max(1, min(batchSize, 10000))");
    expect(source).toContain("operations_cleanup_expired($1,$2,$3::integer)::bigint");
    expect(source).toContain("s.Environment, at, batchSize");
    expect(migration).toContain("requested_batch_size INTEGER DEFAULT 1000");
    expect(migration).toContain("RETURNS BIGINT");
    expect(source).toContain("status IN ('applied','filtered_scope') OR (status='dead_letter' AND reconciled_at IS NOT NULL)");
    expect(source).toContain("inbox.environment=expired.environment AND inbox.source_generation=expired.source_generation AND inbox.seq=expired.seq");
    expect(source).toContain("FOR UPDATE SKIP LOCKED");
    expect(source).toContain("at.Add(-48 * time.Hour)");
    expect(source).toContain("status IN ('completed','failed')");
    expect(source).toContain("at.Add(-30 * 24 * time.Hour)");
  });
});
