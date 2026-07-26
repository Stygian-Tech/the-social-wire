import { describe, expect, it } from "bun:test"
import { backfillProgressEvidence, backfillProgressPercent } from "@/lib/backfill-progress"
import type { Backfill } from "@/lib/operations-types"

const job: Backfill = {
  id: "bf-test-001",
  environment: "dev",
  version: 1,
  sourceMode: "jetstream_replay",
  status: "running",
  collections: ["site.standard.document"],
  authorDids: [],
  authorResults: [],
  batchSize: 1000,
  rateLimit: 500,
  maxConcurrency: 4,
  estimatedCount: 1000,
  processedCount: 500,
  failedCount: 0,
  reconciledCount: 0,
  requestedByDid: "did:plc:operator",
  auditNote: "Recover gap",
  createdAt: "2026-07-20T20:00:00.000Z",
  updatedAt: "2026-07-20T20:00:30.000Z",
  verificationStatus: "required",
  scopeTruncated: false,
}

describe("backfillProgressPercent", () => {
  it("uses processed work while a job is active", () => {
    expect(backfillProgressPercent(job)).toBe(50)
  })

  it("does not fabricate full progress from a completed status", () => {
    const completed = { ...job, status: "completed" as const, processedCount: 0 }

    expect(backfillProgressPercent(completed)).toBe(0)
    expect(backfillProgressEvidence(completed).percentOfEstimate).toBe(0)
  })

  it("preserves partial progress for a failed job", () => {
    expect(backfillProgressPercent({ ...job, status: "failed", processedCount: 250 })).toBe(25)
  })

  it("keeps the visual bounded while exposing estimate overruns", () => {
    const progress = backfillProgressEvidence({ ...job, processedCount: 1_250 })

    expect(progress.percentOfEstimate).toBe(125)
    expect(progress.boundedPercent).toBe(100)
  })

  it("withholds a percentage for invalid telemetry", () => {
    const progress = backfillProgressEvidence({ ...job, processedCount: -1 })

    expect(progress.valid).toBe(false)
    expect(progress.percentOfEstimate).toBeNull()
    expect(progress.boundedPercent).toBe(0)
  })
})
