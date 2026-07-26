import { describe, expect, test } from "bun:test"
import {
  backfillReadiness,
  canQueueBackfill,
  filterTraces,
  jetstreamStateForOverview,
  productionConfirmationMatches,
} from "@/lib/operations-policy"
import type { Span } from "@/lib/operations-types"
import { demoOverview } from "@/lib/demo-data"

describe("operations mutation safeguards", () => {
  test("requires the exact production environment confirmation", () => {
    expect(productionConfirmationMatches("prod", "prod")).toBe(false)
    expect(productionConfirmationMatches("prod", "PRODUCTION")).toBe(true)
    expect(productionConfirmationMatches("dev", "")).toBe(true)
  })

  test("requires collection scope, dry-run, review, and an idle mutation", () => {
    const ready = {
      collectionScopeSelected: true,
      dryRunComplete: true,
      dryRunConflictFree: true,
      reviewed: true,
      environment: "dev" as const,
      environmentConfirmation: "",
      pending: false,
    }
    expect(canQueueBackfill(ready)).toBe(true)
    expect(canQueueBackfill({ ...ready, collectionScopeSelected: false })).toBe(false)
    expect(canQueueBackfill({ ...ready, dryRunComplete: false })).toBe(false)
    expect(canQueueBackfill({ ...ready, dryRunConflictFree: false })).toBe(false)
    expect(canQueueBackfill({ ...ready, reviewed: false })).toBe(false)
    expect(canQueueBackfill({ ...ready, pending: true })).toBe(false)
  })

  test("reports the exact unmet backfill requirements", () => {
    const requirements = backfillReadiness({
      collectionScopeSelected: true,
      dryRunComplete: true,
      dryRunConflictFree: true,
      reviewed: false,
      environment: "prod",
      environmentConfirmation: "prod",
      pending: false,
    })
    expect(requirements.filter((requirement) => !requirement.complete).map((requirement) => requirement.id)).toEqual([
      "reviewed",
      "production-confirmation",
    ])
  })
})

test("trace filtering searches bounded attributes", () => {
  const spans = [
    {
      id: "1",
      environment: "dev",
      traceId: "abc",
      service: "appview",
      name: "appview.db.query",
      startedAt: "2026-01-01T00:00:00Z",
      durationMs: 10,
      status: "ok",
      attributes: { query_name: "sidebar" },
      expiresAt: "2026-01-02T00:00:00Z",
    },
  ] satisfies Span[]
  expect(filterTraces(spans, "sidebar")).toHaveLength(1)
  expect(filterTraces(spans, "raw-did")).toHaveLength(0)
})

test("selects supplemental Jetstream version when Tap is the ingestion authority", () => {
  const jetstream = { ...demoOverview.ingestion!, source: "jetstream", version: 7 }
  const tap = { ...demoOverview.ingestion!, source: "tap", version: 99 }
  expect(jetstreamStateForOverview({
    ...demoOverview,
    ingestion: tap,
    ingestionSources: [tap, jetstream],
  })?.version).toBe(7)
})
