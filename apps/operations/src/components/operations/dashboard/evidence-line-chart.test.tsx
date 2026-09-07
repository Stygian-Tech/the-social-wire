import { afterEach, expect, test } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { EvidenceLineChart, formatChartTick } from "@/components/operations/dashboard/evidence-line-chart"

afterEach(cleanup)

test("distinguishes low-volume rate ticks without rounding observations down to zero", () => {
  expect([0, 0.004, 0.008, 0.012, 0.016].map(formatChartTick)).toEqual([
    "0", "0.004", "0.008", "0.012", "0.016",
  ])
  expect(formatChartTick(1 / 60)).toBe("0.017")
  expect(formatChartTick(0.00004)).toBe("0.00004")
  expect(formatChartTick(0.5)).toBe("0.5")
  expect(formatChartTick(1_611)).toBe("1.6K")
  expect(formatChartTick(1_600_000)).toBe("1.6M")
  expect(formatChartTick(16_000_000_000)).toBe("16B")
})

test("keeps isolated zero and nonzero observations visible without bridging missing buckets", () => {
  const { container } = render(
    <EvidenceLineChart
      title="Sparse Collection Activity"
      unit="events per second"
      source="Observed rollups"
      format={String}
      refreshedAt="2026-07-22T01:08:00Z"
      points={[null, 0, null, 4, null, 2, 3, null].map((value, minute) => ({
        timestamp: Date.UTC(2026, 6, 22, 1, minute),
        value,
      }))}
    />,
  )

  const dots = container.querySelectorAll("circle[r='3']")
  expect(dots).toHaveLength(2)
  expect(Number(dots[0].getAttribute("cy"))).toBeGreaterThan(Number(dots[1].getAttribute("cy")))
  expect(container.querySelector(".recharts-area-curve")?.getAttribute("d")?.match(/M/g)).toHaveLength(3)
  expect(screen.getByText("Coverage: 4/8 buckets (50%)")).toBeTruthy()
  expect(screen.getAllByText("Missing")).toHaveLength(4)
})

test("renders visible provenance, window, latest value, and missing-bucket coverage", () => {
  render(
    <EvidenceLineChart
      title="Indexed Events/sec."
      unit="indexed events per second"
      source="Charybdis metric rollups"
      format={(value) => `${value.toFixed(1)} indexed events/sec`}
      refreshedAt="2026-07-22T01:03:00Z"
      referenceTime="2026-07-22T01:03:00Z"
      points={[
        { timestamp: Date.UTC(2026, 6, 22, 1, 0), value: 2 },
        { timestamp: Date.UTC(2026, 6, 22, 1, 1), value: null },
        { timestamp: Date.UTC(2026, 6, 22, 1, 2), value: 4 },
      ]}
    />,
  )

  expect(screen.getAllByText("4.0 indexed events/sec").length).toBeGreaterThan(0)
  expect(
    screen.getByText("Source: Charybdis metric rollups · reported"),
  ).toBeTruthy()
  expect(screen.getByText("Coverage: 2/3 buckets (67%)")).toBeTruthy()
  expect(screen.getByText("Partial")).toBeTruthy()
  expect(screen.getByRole("img").querySelector("svg")?.getAttribute("viewBox")).toBe("0 0 480 280")
  expect(screen.getByText("Coverage: 2/3 buckets (67%)").closest("[data-slot=card-footer]")?.className).toContain("text-[11px]")
  const curve = screen.getByRole("img").querySelector(".recharts-area-curve")
  expect(curve).toBeTruthy()
  expect(curve?.getAttribute("d")?.match(/M/g)).toHaveLength(2)
  expect(screen.getByRole("img").querySelector(".recharts-area-area")?.getAttribute("fill-opacity")).toBe("0.25")
})

test("ages previously fresh chart evidence against current time", () => {
  const { rerender } = render(
    <EvidenceLineChart
      title="Indexed Events/sec"
      unit="indexed events per second"
      source="Charybdis metric rollups"
      format={(value) => `${value.toFixed(1)} indexed events/sec`}
      refreshedAt="2026-07-22T01:03:00Z"
      referenceTime="2026-07-22T01:03:00Z"
      evidence={{
        source: "Charybdis metric rollups",
        accuracy: "exact",
        generatedAt: "2026-07-22T01:03:00Z",
        ageSeconds: 0,
        validUntil: "2026-07-22T01:04:15Z",
      }}
      points={[{ timestamp: Date.UTC(2026, 6, 22, 1, 2), value: 4 }]}
    />,
  )
  expect(screen.getByText("Fresh")).toBeTruthy()

  rerender(
    <EvidenceLineChart
      title="Indexed Events/sec"
      unit="indexed events per second"
      source="Charybdis metric rollups"
      format={(value) => `${value.toFixed(1)} indexed events/sec`}
      refreshedAt="2026-07-22T01:03:00Z"
      referenceTime="2026-07-22T01:05:00Z"
      evidence={{
        source: "Charybdis metric rollups",
        accuracy: "exact",
        generatedAt: "2026-07-22T01:03:00Z",
        ageSeconds: 0,
        validUntil: "2026-07-22T01:04:15Z",
      }}
      points={[{ timestamp: Date.UTC(2026, 6, 22, 1, 2), value: 4 }]}
    />,
  )
  expect(screen.getByText("Stale")).toBeTruthy()
})

test("can defer freshness status to a section-level indicator", () => {
  render(
    <EvidenceLineChart
      title="Average Database Commit Duration"
      unit="milliseconds"
      source="Charybdis database-write duration rollups"
      format={(value) => `${value} ms`}
      refreshedAt="2026-07-22T01:03:00Z"
      points={[{ timestamp: Date.UTC(2026, 6, 22, 1, 2), value: 4 }]}
      showFreshnessBadge={false}
    />,
  )

  expect(screen.queryByText("Fresh")).toBeNull()
  expect(screen.getByText("Latest bucket age: 0s")).toBeTruthy()
})

test("uses non-duplicated truthful ticks for an observed all-zero series", () => {
  render(
    <EvidenceLineChart
      title="Failed Events/sec."
      unit="failed events per second"
      source="Charybdis metric rollups"
      format={(value) => `${value} failures/sec`}
      refreshedAt="2026-07-22T01:03:00Z"
      points={[
        { timestamp: Date.UTC(2026, 6, 22, 1, 1), value: 0 },
        { timestamp: Date.UTC(2026, 6, 22, 1, 2), value: 0 },
      ]}
    />,
  )

  const ticks = Array.from(screen.getByRole("img").querySelectorAll("text")).map((node) => node.textContent)
  expect(ticks).toContain("0")
  expect(ticks).toContain("0.5")
  expect(ticks).toContain("1")
})

test("uses compact tick labels while keeping the full unit in the chart header", () => {
  render(
    <EvidenceLineChart
      title="Indexed Events/sec."
      unit="indexed events per second"
      source="Charybdis metric rollups"
      format={(value) => `${value.toLocaleString()} indexed events/sec`}
      refreshedAt="2026-07-22T01:03:00Z"
      points={[
        { timestamp: Date.UTC(2026, 6, 22, 1, 1), value: 0 },
        { timestamp: Date.UTC(2026, 6, 22, 1, 2), value: 1_611 },
      ]}
    />,
  )

  const ticks = Array.from(screen.getByRole("img").querySelectorAll("text")).map((node) => node.textContent)
  expect(ticks).toContain("1.6K")
  expect(screen.getAllByText(/indexed events per second/).length).toBeGreaterThanOrEqual(2)
  expect(screen.getByRole("table", { name: "Indexed Events\/sec. time-series data" })).toBeTruthy()
})
