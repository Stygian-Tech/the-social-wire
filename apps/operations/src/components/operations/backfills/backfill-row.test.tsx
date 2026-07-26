import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { BackfillRow } from "@/components/operations/backfills/backfill-row"
import { Table, TableBody } from "@/components/ui/table"
import type { Backfill } from "@/lib/operations-types"

afterEach(cleanup)

const completedJob: Backfill = {
  id: "bf-completed-empty",
  environment: "dev",
  version: 1,
  sourceMode: "jetstream_replay",
  status: "completed",
  collections: ["site.standard.document"],
  authorDids: [],
  authorResults: [],
  batchSize: 1000,
  rateLimit: 500,
  maxConcurrency: 4,
  estimatedCount: 1000,
  processedCount: 0,
  failedCount: 0,
  reconciledCount: 0,
  requestedByDid: "did:plc:operator",
  auditNote: "Recover gap",
  createdAt: "2026-07-20T20:00:00.000Z",
  updatedAt: "2026-07-20T20:00:30.000Z",
  verificationStatus: "required",
  scopeTruncated: false,
}

describe("BackfillRow", () => {
  it("keeps completed status separate from observed progress", () => {
    render(
      <Table>
        <TableBody>
          <BackfillRow job={completedJob} environment="dev" />
        </TableBody>
      </Table>,
    )

    expect(screen.getByText("0% est.")).toBeTruthy()
    expect(
      screen.getByRole("progressbar", { name: "Backfill bf-completed-empty progress" }).getAttribute("aria-valuenow"),
    ).toBe("0")
  })

  it("shows the persisted failure reason for failed jobs", () => {
    render(
      <Table>
        <TableBody>
          <BackfillRow
            job={{ ...completedJob, status: "failed", failureReason: "database_timeout" }}
            environment="dev"
          />
        </TableBody>
      </Table>,
    )

    expect(screen.getByRole("alert").textContent).toContain("Failure Reason: database timeout")
  })

  it("labels PDS reconciliation throttles as request rate", () => {
    render(
      <Table>
        <TableBody>
          <BackfillRow job={{ ...completedJob, sourceMode: "pds_reconciliation" }} environment="dev" />
        </TableBody>
      </Table>,
    )

    expect(screen.getByText("≤ 500 PDS requests/s")).toBeTruthy()
    expect(screen.queryByText("≤ 500 source events/s")).toBeNull()
  })
})
