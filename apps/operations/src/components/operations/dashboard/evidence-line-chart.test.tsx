import { afterEach, expect, test } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { EvidenceLineChart } from "@/components/operations/dashboard/evidence-line-chart"

afterEach(cleanup)

test("renders visible provenance, window, latest value, and missing-bucket coverage", () => {
  render(
    <EvidenceLineChart
      title="Indexed Events/sec."
      unit="indexed events per second"
      source="AppView Worker metric rollups"
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
    screen.getByText("Source: AppView Worker metric rollups · reported"),
  ).toBeTruthy()
  expect(screen.getByText("Coverage: 2/3 buckets (67%)")).toBeTruthy()
  expect(screen.getByText("Partial")).toBeTruthy()
  expect(screen.getByRole("img").getAttribute("viewBox")).toBe("0 0 480 280")
  expect(screen.getByText("Coverage: 2/3 buckets (67%)").closest("footer")?.className).toContain("text-[11px]")
  expect(screen.getByRole("img").querySelector("text")?.getAttribute("font-size")).toBe("11")
})

test("ages previously fresh chart evidence against current time", () => {
  const { rerender } = render(
    <EvidenceLineChart
      title="Indexed Events/sec"
      unit="indexed events per second"
      source="AppView Worker metric rollups"
      format={(value) => `${value.toFixed(1)} indexed events/sec`}
      refreshedAt="2026-07-22T01:03:00Z"
      referenceTime="2026-07-22T01:03:00Z"
      evidence={{
        source: "AppView Worker metric rollups",
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
      source="AppView Worker metric rollups"
      format={(value) => `${value.toFixed(1)} indexed events/sec`}
      refreshedAt="2026-07-22T01:03:00Z"
      referenceTime="2026-07-22T01:05:00Z"
      evidence={{
        source: "AppView Worker metric rollups",
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
      source="AppView Worker database-write duration rollups"
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
      source="AppView Worker metric rollups"
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
      source="AppView Worker metric rollups"
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
  expect(screen.getByText(/indexed events per second/)).toBeTruthy()
})
