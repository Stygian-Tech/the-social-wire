import { afterEach, expect, test } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { UserCounts } from "@/components/operations/dashboard/user-counts"
import { demoOverview } from "@/lib/demo-data"

afterEach(cleanup)

test("shows known and active user counts", () => {
  render(<UserCounts overview={demoOverview} />)
  expect(screen.getByText("1,284")).toBeTruthy()
  expect(screen.getByText("412")).toBeTruthy()
  expect(screen.getByText("906")).toBeTruthy()
})

test("states that counts are viewer projections rather than registrations", () => {
  render(<UserCounts overview={demoOverview} />)
  expect(screen.getByText(/not a\s+registration count/)).toBeTruthy()
})

test("degrades to an explanation when the service reports no viewer counts", () => {
  render(<UserCounts overview={{ ...demoOverview, viewers: undefined }} />)
  expect(screen.getByText(/User counts are unavailable/)).toBeTruthy()
  expect(screen.queryByText("1,284")).toBeNull()
})

test("ignores malformed counts instead of rendering them", () => {
  render(
    <UserCounts
      overview={{
        ...demoOverview,
        viewers: {
          knownViewers: -1,
          activeViewers7d: Number.NaN,
          activeViewers30d: 906,
          observedAt: demoOverview.refreshedAt,
        },
      }}
    />,
  )
  expect(screen.getAllByText("—")).toHaveLength(2)
  expect(screen.getByText("906")).toBeTruthy()
})
