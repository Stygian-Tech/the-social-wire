import { describe, expect, test } from "bun:test"
import { allowedBackfillActions, partitionBackfills } from "@/lib/backfill-lifecycle"
import type { Backfill } from "@/lib/operations-types"

function job(status: Backfill["status"]): Backfill {
  return {
    id: status,
    environment: "dev",
    version: 1,
    sourceMode: "jetstream_replay",
    status,
    collections: ["site.standard.document"],
    authorDids: [],
    authorResults: [],
    batchSize: 100,
    rateLimit: 100,
    maxConcurrency: 1,
    estimatedCount: 1,
    processedCount: 0,
    failedCount: 0,
    reconciledCount: 0,
    requestedByDid: "did:plc:test",
    auditNote: "",
    createdAt: "2026-07-22T00:00:00Z",
    updatedAt: "2026-07-22T00:00:00Z",
    verificationStatus: "required",
    scopeTruncated: false,
  }
}

describe("backfill lifecycle", () => {
  test("keeps terminal jobs out of Active", () => {
    const result = partitionBackfills(
      (["queued", "running", "paused", "failed", "cancelled", "completed"] as const).map(job),
    )

    expect(result.active.map(({ status }) => status)).toEqual(["queued", "running", "paused"])
    expect(result.needsAttention.map(({ status }) => status)).toEqual(["failed", "cancelled"])
    expect(result.history.map(({ status }) => status)).toEqual(["completed"])
  })

  test("exposes only legal operator actions", () => {
    expect(allowedBackfillActions("queued")).toEqual(["cancel"])
    expect(allowedBackfillActions("running")).toEqual(["pause", "cancel"])
    expect(allowedBackfillActions("paused")).toEqual(["resume", "cancel"])
    expect(allowedBackfillActions("completed")).toEqual([])
  })
})
