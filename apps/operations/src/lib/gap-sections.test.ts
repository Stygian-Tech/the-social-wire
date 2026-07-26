import { describe, expect, it } from "bun:test"
import { partitionGapsByBackfillCompletion } from "@/lib/gap-sections"
import type { Backfill, Gap } from "@/lib/operations-types"

const gap = (overrides: Partial<Gap> = {}): Gap => ({
  id: "gap-1",
  environment: "dev",
  version: 1,
  source: "jetstream",
  reason: "consumer_restart",
  status: "confirmed",
  collections: ["site.standard.document"],
  detectedAt: "2026-07-20T20:00:00.000Z",
  updatedAt: "2026-07-20T20:00:00.000Z",
  discoveredCount: 10,
  processedCount: 0,
  failedCount: 0,
  reconciledCount: 0,
  ...overrides,
})

const backfill = (overrides: Partial<Backfill> = {}): Backfill => ({
  id: "backfill-1",
  environment: "dev",
  version: 1,
  gapId: "gap-1",
  sourceMode: "jetstream_replay",
  status: "completed",
  collections: ["site.standard.document"],
  authorDids: [],
  authorResults: [],
  batchSize: 1000,
  rateLimit: 500,
  maxConcurrency: 4,
  estimatedCount: 10,
  processedCount: 10,
  failedCount: 0,
  reconciledCount: 0,
  requestedByDid: "did:plc:operator",
  auditNote: "Recover gap",
  createdAt: "2026-07-20T20:00:00.000Z",
  updatedAt: "2026-07-20T20:00:30.000Z",
  verificationStatus: "required",
  scopeTruncated: false,
  ...overrides,
})

describe("partitionGapsByBackfillCompletion", () => {
  it("moves a gap with a completed backfill into backfilled history", () => {
    const result = partitionGapsByBackfillCompletion([gap()], [backfill()])

    expect(result.activeGaps).toEqual([])
    expect(result.backfilledGaps.map(({ id }) => id)).toEqual(["gap-1"])
  })

  it("keeps gaps active while their backfills are queued, running, or failed", () => {
    for (const status of ["queued", "running", "failed"] as const) {
      const result = partitionGapsByBackfillCompletion([gap()], [backfill({ status })])

      expect(result.activeGaps.map(({ id }) => id)).toEqual(["gap-1"])
      expect(result.backfilledGaps).toEqual([])
    }
  })

  it("recognizes resolved backfilled gaps when the completed job has aged out of the response", () => {
    const resolvedGap = gap({ status: "resolved", backfillJobId: "backfill-old" })
    const result = partitionGapsByBackfillCompletion([resolvedGap], [])

    expect(result.backfilledGaps).toEqual([resolvedGap])
  })

  it("keeps resolved and ignored gaps out of the active list without losing their history", () => {
    const resolvedGap = gap({ id: "gap-resolved", status: "resolved" })
    const ignoredGap = gap({ id: "gap-ignored", status: "ignored" })
    const result = partitionGapsByBackfillCompletion([resolvedGap, ignoredGap], [])

    expect(result.activeGaps).toEqual([])
    expect(result.backfilledGaps).toEqual([])
    expect(result.inactiveGaps).toEqual([resolvedGap, ignoredGap])
  })
})
