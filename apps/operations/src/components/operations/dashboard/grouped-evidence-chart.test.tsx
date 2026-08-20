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
  expect(screen.getByText("Average")).toBeTruthy()
  expect(screen.getByText("Maximum")).toBeTruthy()
  expect(screen.getByText("Source: Operations rollups")).toBeTruthy()
  expect(screen.getByText("Coverage: 3/4 values (75%)")).toBeTruthy()
  expect(screen.getByText("Samples: 3")).toBeTruthy()
})
