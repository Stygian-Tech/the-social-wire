import { afterEach, expect, test } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"

import {
  GroupedEvidenceChart,
  mergeGroupedSeries,
} from "@/components/operations/dashboard/grouped-evidence-chart"

afterEach(cleanup)

test("merges related series onto one timeline without connecting missing values", () => {
  expect(mergeGroupedSeries([
    { key: "average", points: [{ timestamp: 1, value: 2 }, { timestamp: 2, value: null }] },
    { key: "maximum", points: [{ timestamp: 2, value: 8 }] },
  ])).toEqual([
    { timestamp: 1, average: 2, maximum: null },
    { timestamp: 2, average: null, maximum: 8 },
  ])
})

test("renders shadcn chart provenance, legend, and coverage for grouped evidence", () => {
  render(
    <GroupedEvidenceChart
      title="Commit Duration"
      description="Average and maximum"
      unit="milliseconds"
      source="Operations rollups"
      data={[
        { timestamp: Date.parse("2026-08-20T12:00:00Z"), average: 2, maximum: 8 },
        { timestamp: Date.parse("2026-08-20T12:01:00Z"), average: -1, maximum: 6 },
      ]}
      series={[
        { key: "average", label: "Average", color: "var(--primary)" },
        { key: "maximum", label: "Maximum", color: "var(--warning)", dashed: true },
      ]}
      sampleCount={3}
    />,
  )

  expect(screen.getByRole("img").getAttribute("aria-label")).toContain("3 of 4 values observed")
  expect(screen.getAllByText("Average").length).toBeGreaterThanOrEqual(2)
  expect(screen.getAllByText("Maximum").length).toBeGreaterThanOrEqual(2)
  expect(screen.getByRole("table", { name: "Commit Duration time-series data" })).toBeTruthy()
  expect(screen.getByText("Source: Operations rollups")).toBeTruthy()
  expect(screen.getByText("Coverage: 3/4 values (75%)")).toBeTruthy()
  expect(screen.getByText("Samples: 3")).toBeTruthy()
})

test("keeps filled comparisons separate and preserves gaps and explicit dashed maxima", () => {
  const { container } = render(
    <GroupedEvidenceChart
      title="Daily Observations"
      description="Average and maximum"
      unit="users"
      source="Observed daily samples"
      data={[
        { timestamp: 1, average: 2, maximum: 8 },
        { timestamp: 2, average: 3, maximum: 9 },
        { timestamp: 3, average: null, maximum: 10 },
        { timestamp: 4, average: 4, maximum: 8 },
        { timestamp: 5, average: 5, maximum: 7 },
      ]}
      series={[
        { key: "average", label: "Average", color: "var(--chart-1)" },
        { key: "maximum", label: "Maximum", color: "var(--chart-1)", dashed: true },
      ]}
    />,
  )
  const curves = container.querySelectorAll(".recharts-area-curve")
  expect(curves).toHaveLength(2)
  expect(curves[0].getAttribute("d")?.match(/M/g)).toHaveLength(2)
  expect(curves[0].getAttribute("stroke-dasharray")).toBeNull()
  expect(curves[1].getAttribute("stroke-dasharray")).toBe("5 4")
  expect(container.querySelectorAll(".recharts-area-area")).toHaveLength(2)
  expect(screen.getByText("Missing")).toBeTruthy()
})
