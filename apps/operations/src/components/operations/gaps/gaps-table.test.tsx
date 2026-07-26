import { afterEach, describe, expect, it, mock } from "bun:test"
import { cleanup, render, screen, within } from "@testing-library/react"
import { GapsTable } from "@/components/operations/gaps/gaps-table"
import type { Backfill, Gap } from "@/lib/operations-types"

afterEach(cleanup)

const activeGap: Gap = {
  id: "gap-active",
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
}

const backfilledGap: Gap = {
  ...activeGap,
  id: "gap-backfilled",
  status: "resolved",
  backfillJobId: "backfill-completed",
}

const completedBackfill: Backfill = {
  id: "backfill-completed",
  environment: "dev",
  version: 1,
  gapId: "gap-backfilled",
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
  completedAt: "2026-07-20T20:00:30.000Z",
  verificationStatus: "required",
  scopeTruncated: false,
}

describe("GapsTable", () => {
  it("keeps completed recoveries out of the active lifecycle view", () => {
    render(
      <GapsTable
        gaps={[activeGap, backfilledGap]}
        backfills={[completedBackfill]}
        onSelect={mock()}
        onInvestigate={mock()}
        expanded
      />,
    )

    const activeSection = screen.getByRole("heading", { name: "Active Gaps (1)" }).closest("section")
    expect(activeSection).not.toBeNull()
    expect(within(activeSection!).getAllByRole("button", { name: "Backfill gap gap-active" }).length).toBeGreaterThan(0)
    expect(within(activeSection!).queryByText("resolved")).toBeNull()
    expect(screen.getByRole("link", { name: "History" })).toBeTruthy()
  })

  it("keeps resolved gaps without backfills out of active gaps and in expanded history", () => {
    const resolvedGap = { ...activeGap, id: "gap-resolved", status: "resolved" as const }
    render(
      <GapsTable
        gaps={[activeGap, resolvedGap]}
        backfills={[]}
        onSelect={mock()}
        onInvestigate={mock()}
        expanded
        view="history"
      />,
    )

    const inactiveSection = screen
      .getByRole("heading", { name: "Resolved / Ignored Gap History (1)" })
      .closest("section")

    expect(within(inactiveSection!).getAllByText("resolved").length).toBeGreaterThan(0)
    expect(within(inactiveSection!).queryByRole("button", { name: /Backfill gap/ })).toBeNull()
  })

  it("does not claim the active list is empty when only a nonzero server count is available", () => {
    render(
      <GapsTable
        gaps={[]}
        backfills={[]}
        counts={{
          activeGaps: 3,
          activeBackfills: 0,
          attentionBackfills: 0,
          completedBackfills: 0,
          unresolvedAlerts: 0,
        }}
        onSelect={mock()}
        onInvestigate={mock()}
      />,
    )

    expect(screen.getByRole("heading", { name: "Active Gaps (3)" })).toBeTruthy()
    expect(
      screen.getByText("3 active gaps are reported, but row evidence is unavailable in this response."),
    ).toBeTruthy()
    expect(screen.queryByText("No active gaps.")).toBeNull()
  })
})
