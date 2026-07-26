import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { BackfillProgress, isBackfillTerminal } from "@/components/operations/backfills/backfill-progress"
import type { Backfill } from "@/lib/operations-types"

afterEach(cleanup)

const job: Backfill = {
  id: "bf-test-001",
  environment: "dev",
  version: 1,
  gapId: "gap-test-001",
  sourceMode: "jetstream_replay",
  status: "running",
  startCursor: 100,
  endCursor: 200,
  checkpointCursor: 150,
  collections: ["site.standard.document"],
  authorDids: [],
  authorResults: [],
  batchSize: 1000,
  rateLimit: 500,
  maxConcurrency: 4,
  estimatedCount: 1000,
  processedCount: 500,
  failedCount: 2,
  reconciledCount: 40,
  requestedByDid: "did:plc:operator",
  auditNote: "Recover the confirmed gap",
  leaseOwner: "worker-01",
  leaseExpiresAt: "2026-07-20T20:01:00.000Z",
  createdAt: "2026-07-20T20:00:00.000Z",
  updatedAt: "2026-07-20T20:00:30.000Z",
  verificationStatus: "required",
  scopeTruncated: false,
}

describe("BackfillProgress", () => {
  it("shows live status, checkpoint, and progress metrics", () => {
    render(<BackfillProgress job={job} refreshing />)

    expect(screen.getByText("Running")).toBeTruthy()
    expect(screen.getByText("50% of estimate")).toBeTruthy()
    expect(screen.getByText("500 observed / ~1,000 estimated")).toBeTruthy()
    expect(screen.getByText("Live Updates Every 2 Seconds")).toBeTruthy()
    expect(screen.getByText("worker-01")).toBeTruthy()
    const progressbar = screen.getByRole("progressbar", { name: "Backfill bf-test-001 progress" })
    expect(progressbar.getAttribute("aria-valuenow")).toBe("50")
  })

  it("stops describing terminal jobs as live", () => {
    render(<BackfillProgress job={{ ...job, status: "completed", processedCount: 0 }} refreshing={false} />)

    expect(screen.getByText("Final Status")).toBeTruthy()
    expect(screen.getByText("0% of estimate")).toBeTruthy()
    expect(screen.getByRole("progressbar").getAttribute("aria-valuenow")).toBe("0")
    expect(screen.getByText("Run Finished; Estimate Did Not Match")).toBeTruthy()
    expect(screen.getByText(/Completion describes the scan state/)).toBeTruthy()
    expect(isBackfillTerminal("completed")).toBe(true)
    expect(isBackfillTerminal("running")).toBe(false)
  })

  it("warns when a queued job has not been claimed", () => {
    render(
      <BackfillProgress
        job={{ ...job, status: "queued", processedCount: 0, createdAt: "2026-07-20T19:00:00.000Z" }}
        refreshing={false}
      />,
    )

    expect(screen.getByText("Waiting for Worker")).toBeTruthy()
    expect(
      screen.getByText(
        "This job is queued but has not been claimed. Check the AppView Worker and its Operations database configuration if this state persists.",
      ),
    ).toBeTruthy()
  })

  it("explains why a failed job stopped", () => {
    render(
      <BackfillProgress
        job={{ ...job, status: "failed", failureReason: "upstream_unavailable" }}
        refreshing={false}
      />,
    )

    expect(screen.getByText("Backfill Failed")).toBeTruthy()
    expect(screen.getByText("Failure Reason: upstream unavailable")).toBeTruthy()
  })

  it("renders durable per-author diagnostic scope and outcome evidence", () => {
    render(
      <BackfillProgress
        job={{
          ...job,
          sourceMode: "pds_reconciliation",
          authorDids: ["did:plc:author"],
          authorResults: [
            {
              did: "did:plc:author",
              collection: "site.standard.document",
              discoveredCount: 12,
              processedCount: 10,
              failedCount: 2,
              capped: true,
              truncated: true,
              status: "partial",
              error: "rate_limit_exhausted",
            },
          ],
        }}
        refreshing={false}
      />,
    )

    expect(screen.getByText("12 discovered · 10 processed · 2 failed · partial")).toBeTruthy()
    expect(screen.getByText("scope cap reached")).toBeTruthy()
    expect(screen.getAllByRole("alert").some((alert) => alert.textContent?.includes("rate_limit_exhausted"))).toBe(true)
  })

  it("withholds progress when counts are invalid", () => {
    render(<BackfillProgress job={{ ...job, processedCount: -1 }} refreshing={false} />)

    expect(screen.getByText("Not Measurable")).toBeTruthy()
    expect(screen.getByText("Invalid Progress Telemetry")).toBeTruthy()
    expect(screen.getByRole("progressbar", { name: "Backfill bf-test-001 progress" }).hasAttribute("aria-valuenow")).toBe(false)
  })
})
