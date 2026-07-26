import { afterEach, expect, test } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { CollectionHealth } from "@/components/operations/dashboard/collection-health"
import { demoOverview } from "@/lib/demo-data"

afterEach(cleanup)

const metricsEvidence = {
  source: "AppView Worker metric rollups",
  accuracy: "exact" as const,
  generatedAt: demoOverview.refreshedAt,
  ageSeconds: 0,
  validUntil: new Date(new Date(demoOverview.refreshedAt).getTime() + 75_000).toISOString(),
  coverage: 1,
}

test("uses one section-level freshness counter instead of per-chart badges", () => {
  render(
    <CollectionHealth
      metricRollups={demoOverview.metricRollups}
      refreshedAt={demoOverview.refreshedAt}
      referenceTime={demoOverview.refreshedAt}
      evidence={metricsEvidence}
    />,
  )

  expect(screen.getAllByText(/(?:Current|Partial|Expired|Unavailable) · \d+s old/)).toHaveLength(1)
  expect(screen.queryByText("Fresh")).toBeNull()
  expect(screen.getAllByText(/Latest bucket age:/).length).toBeGreaterThan(1)
})

test("ages the shared counter once for the whole section", () => {
  const referenceTime = new Date(
    new Date(metricsEvidence.generatedAt).getTime() + 120_000,
  ).toISOString()
  render(
    <CollectionHealth
      metricRollups={demoOverview.metricRollups}
      refreshedAt={demoOverview.refreshedAt}
      referenceTime={referenceTime}
      evidence={metricsEvidence}
    />,
  )

  expect(screen.getByText(/Expired · \d+s old/)).toBeTruthy()
  expect(screen.getAllByText(/Expired/)).toHaveLength(1)
})
