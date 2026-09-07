import { afterEach, expect, test } from "bun:test"
import { cleanup, render, screen, within } from "@testing-library/react"
import { UserCounts } from "@/components/operations/dashboard/user-counts"
import { demoOverview } from "@/lib/demo-data"

afterEach(cleanup)

test("shows known and active user counts", () => {
  render(<UserCounts overview={demoOverview} />)
  expect(screen.getAllByText("1,284").length).toBeGreaterThan(0)
  expect(screen.getAllByText("412").length).toBeGreaterThan(0)
  expect(screen.getAllByText("906").length).toBeGreaterThan(0)
})

test("states that counts are viewer projections rather than registrations", () => {
  render(<UserCounts overview={demoOverview} />)
  expect(screen.getByText(/not a\s+registration count/)).toBeTruthy()
})

test("degrades to an explanation when the service reports no viewer counts", () => {
  render(<UserCounts overview={{ ...demoOverview, viewers: undefined, viewerHistory: [] }} />)
  expect(screen.getByText(/User counts are unavailable/)).toBeTruthy()
  expect(screen.queryByText("1,284")).toBeNull()
})

test("ignores malformed counts instead of rendering them", () => {
  render(
    <UserCounts
      overview={{
        ...demoOverview,
        viewerHistory: [],
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

test("plots known users, MAUs, and WAUs on one daily chart", () => {
  render(<UserCounts overview={demoOverview} />)
  const chart = screen.getByRole("img")
  expect(chart.getAttribute("aria-label")).toContain("3 series over 90 UTC days")
  const table = screen.getByRole("table", { name: "Users Over Time time-series data" })
  expect(within(table).getAllByRole("columnheader").map((cell) => cell.textContent)).toEqual([
    "Time", "Known Users", "MAUs", "WAUs",
  ])
  expect(within(table).getAllByRole("row")).toHaveLength(91)
})

test("retains history when the current counts are unavailable", () => {
  render(<UserCounts overview={{ ...demoOverview, viewers: undefined }} />)
  expect(screen.getByText(/User counts are unavailable/)).toBeTruthy()
  expect(screen.getByRole("img")).toBeTruthy()
})

test("shows the first daily observation as three visible points with missing days left empty", () => {
  const { container } = render(<UserCounts overview={{
    ...demoOverview,
    viewerHistory: [demoOverview.viewers!],
  }} />)
  expect(screen.getByRole("img").getAttribute("aria-label")).toContain("3 of 270 values observed")
  expect(container.querySelectorAll("circle[r='3']")).toHaveLength(3)
  const table = screen.getByRole("table", { name: "Users Over Time time-series data" })
  expect(within(table).getAllByText("Missing")).toHaveLength(267)
  expect(within(table).getByText("1,284")).toBeTruthy()
})

test("explains that history is collecting without inventing a trend from current counts", () => {
  render(<UserCounts overview={{ ...demoOverview, viewerHistory: undefined }} />)
  expect(screen.getByText(/No daily user history is available yet/)).toBeTruthy()
  expect(screen.queryByRole("img")).toBeNull()
})
