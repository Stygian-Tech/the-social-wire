import { afterEach, describe, expect, it, mock } from "bun:test"
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import type { ReactElement } from "react"
import { GapsTable } from "@/components/operations/gaps/gaps-table"
import { OperationsAuthProvider } from "@/lib/auth-context"
import type { Backfill, Gap } from "@/lib/operations-types"

afterEach(cleanup)
process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE = "1"

function renderGaps(component: ReactElement) {
  const queryClient = new QueryClient()
  render(
    <QueryClientProvider client={queryClient}>
      <OperationsAuthProvider>{component}</OperationsAuthProvider>
    </QueryClientProvider>,
  )
}

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
    renderGaps(
      <GapsTable
        gaps={[activeGap, backfilledGap]}
        backfills={[completedBackfill]}
        onSelect={mock()}
        onInvestigate={mock()}
        expanded
      />,
    )

    const activeSection = screen.getByRole("heading", { name: "Open Legacy V1 Signals (1)" }).closest("section")
    expect(activeSection).not.toBeNull()
    expect(within(activeSection!).getAllByRole("button", { name: "Backfill gap gap-active" }).length).toBeGreaterThan(0)
    expect(within(activeSection!).getAllByRole("button", { name: "Clear legacy gap gap-active" }).length).toBeGreaterThan(0)
    expect(within(activeSection!).queryByText("resolved")).toBeNull()
    expect(screen.getByRole("link", { name: "History" })).toBeTruthy()
  })

  it("explains that clearing archives evidence instead of deleting it", () => {
    renderGaps(
      <GapsTable
        gaps={[activeGap]}
        backfills={[]}
        onSelect={mock()}
        onInvestigate={mock()}
        expanded
      />,
    )

    fireEvent.click(screen.getAllByRole("button", { name: "Clear legacy gap gap-active" })[0]!)

    expect(screen.getByRole("heading", { name: "Clear This Legacy V1 Signal?" })).toBeTruthy()
    expect(screen.getByText(/marks the signal Ignored and moves it to History/i)).toBeTruthy()
    expect(screen.getByText(/does not delete ingestion, recovery, or audit evidence/i)).toBeTruthy()
    expect(screen.getByRole("button", { name: "Clear Signal" }).hasAttribute("disabled")).toBe(true)
  })

  it("keeps resolved gaps without backfills out of active gaps and in expanded history", () => {
    const resolvedGap = { ...activeGap, id: "gap-resolved", status: "resolved" as const }
    renderGaps(
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
    expect(within(inactiveSection!).queryByRole("button", { name: /Clear legacy gap/ })).toBeNull()
  })

  it("does not claim the active list is empty when only a nonzero server count is available", () => {
    renderGaps(
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

    expect(screen.getByRole("heading", { name: "Open Legacy V1 Signals (3)" })).toBeTruthy()
    expect(
      screen.getByText("3 unresolved legacy V1 signals are reported, but row evidence is unavailable in this response."),
    ).toBeTruthy()
    expect(screen.queryByText("No unresolved legacy V1 signals.")).toBeNull()
  })
})
