import { afterEach, expect, test } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { ServiceTable } from "@/components/operations/dashboard/service-table"
import { demoOverview } from "@/lib/demo-data"

afterEach(cleanup)

test("ages service status badges to Unknown after heartbeat evidence expires", () => {
  const referenceTime = new Date(new Date(demoOverview.refreshedAt).getTime() + 60_000).toISOString()
  render(<ServiceTable data={demoOverview} referenceTime={referenceTime} />)

  expect(screen.getAllByText("Unknown").length).toBeGreaterThan(0)
  expect(screen.getAllByText(/expired/i).length).toBeGreaterThan(0)
  expect(screen.queryByText("Fresh")).toBeNull()
})
