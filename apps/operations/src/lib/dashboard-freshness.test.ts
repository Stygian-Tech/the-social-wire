import { expect, test } from "bun:test"
import { dashboardFreshness } from "@/lib/dashboard-freshness"
import { demoOverview } from "@/lib/demo-data"

const generatedAt = "2026-07-22T10:00:00Z"
const validUntil = "2026-07-22T10:02:00Z"
const exactEvidence = {
  source: "test-source",
  accuracy: "exact" as const,
  generatedAt,
  indexedThrough: generatedAt,
  ageSeconds: 0,
  validUntil,
  coverage: 1,
}
const overview = {
  ...demoOverview,
  refreshedAt: generatedAt,
  evidence: {
    services: exactEvidence,
    ingestion: exactEvidence,
    database: exactEvidence,
  },
}

test("distinguishes live, delayed, stale, paused, partial, and offline evidence", () => {
  expect(dashboardFreshness({ overview, autoRefresh: true, requestFailed: false, detailFallback: false, now: Date.parse(generatedAt) + 4_000 }).state).toBe("live")
  expect(dashboardFreshness({ overview, autoRefresh: true, requestFailed: false, detailFallback: false, now: Date.parse(generatedAt) + 20_000 }).state).toBe("delayed")
  expect(dashboardFreshness({ overview, autoRefresh: true, requestFailed: false, detailFallback: false, now: Date.parse(generatedAt) + 76_000 }).state).toBe("stale")
  expect(dashboardFreshness({ overview, autoRefresh: false, requestFailed: false, detailFallback: false, now: Date.parse(generatedAt) + 4_000 }).state).toBe("paused")
  expect(dashboardFreshness({ overview, autoRefresh: true, requestFailed: false, detailFallback: true, now: Date.parse(generatedAt) + 4_000 }).state).toBe("partial")
  expect(dashboardFreshness({ overview: undefined, autoRefresh: true, requestFailed: true, detailFallback: false }).state).toBe("offline")
})

test("uses the oldest real source instead of a nonexistent overview evidence key", () => {
  const database = { ...exactEvidence, source: "pg_stat_database", ageSeconds: 20 }
  const result = dashboardFreshness({
    overview: { ...overview, evidence: { ...overview.evidence, database } },
    autoRefresh: true,
    requestFailed: false,
    detailFallback: false,
    now: Date.parse(generatedAt),
  })

  expect(result.state).toBe("delayed")
  expect(result.ageSeconds).toBe(20)
  expect(result.evidence?.source).toBe("pg_stat_database")
})

test("marks unavailable and expired source evidence instead of reporting the overview live", () => {
  const unavailable = {
    ...exactEvidence,
    source: "operations_service_state",
    accuracy: "unavailable" as const,
    coverage: 0,
    degradedReason: "No current service heartbeat is available.",
  }
  expect(dashboardFreshness({
    overview: { ...overview, evidence: { ...overview.evidence, services: unavailable } },
    autoRefresh: true,
    requestFailed: false,
    detailFallback: false,
    now: Date.parse(generatedAt),
  }).state).toBe("partial")

  const expired = { ...exactEvidence, source: "appview_ingestion_stream_state", validUntil: generatedAt }
  expect(dashboardFreshness({
    overview: { ...overview, evidence: { ...overview.evidence, ingestion: expired } },
    autoRefresh: true,
    requestFailed: false,
    detailFallback: false,
    now: Date.parse(generatedAt) + 1,
  }).state).toBe("stale")
})
