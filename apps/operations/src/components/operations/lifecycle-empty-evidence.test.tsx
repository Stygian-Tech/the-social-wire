import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { BackfillsTable } from "@/components/operations/backfills/backfills-table"
import { AlertsTable } from "@/components/operations/dashboard/alerts-table"
import { demoOverview } from "@/lib/demo-data"

afterEach(cleanup)

describe("lifecycle list evidence", () => {
  it("does not claim the active backfill list is empty when the count is nonzero", () => {
    render(
      <BackfillsTable
        backfills={[]}
        environment="dev"
        mutationsEnabled={false}
        counts={{
          activeGaps: 0,
          activeBackfills: 2,
          attentionBackfills: 0,
          completedBackfills: 0,
          unresolvedAlerts: 0,
        }}
      />,
    )

    expect(
      screen.getByText("2 active backfills are reported, but row evidence is unavailable in this response."),
    ).toBeTruthy()
  })

  it("does not claim the active alert list is empty when the count is nonzero", () => {
    render(
      <AlertsTable
        data={{
          ...demoOverview,
          alerts: [],
          counts: { ...demoOverview.counts, unresolvedAlerts: 4 },
        }}
        environment="dev"
        mutationsEnabled={false}
      />,
    )

    expect(
      screen.getByText("4 unresolved alerts are reported, but row evidence is unavailable in this response."),
    ).toBeTruthy()
  })
})
