import { afterEach, expect, test } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { OperationsDataStatus } from "@/components/operations/dashboard/operations-data-status"
import { demoOverview } from "@/lib/demo-data"

afterEach(cleanup)

test("describes reconnecting event delivery as polling fallback", () => {
  render(
    <OperationsDataStatus
      overview={demoOverview}
      autoRefresh
      requestFailed={false}
      detailFallback={false}
      eventStreamState="reconnecting"
      now={new Date(demoOverview.refreshedAt).getTime()}
    />,
  )

  expect(screen.getByText("Event updates: polling fallback")).toBeTruthy()
  expect(screen.queryByText(/disconnected/i)).toBeNull()
})
