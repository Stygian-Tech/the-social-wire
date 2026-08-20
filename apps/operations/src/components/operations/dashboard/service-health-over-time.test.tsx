import { afterEach, expect, test } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"

import { ServiceHealthOverTime } from "@/components/operations/dashboard/service-health-over-time"
import { SERVICE_HEALTH_METRIC } from "@/lib/observability-values"
import type { MetricRollup } from "@/lib/operations-types"

afterEach(cleanup)

function sample(service: string, dimension: string): MetricRollup {
  return {
    environment: "dev",
    bucketStart: "2026-08-20T12:00:00Z",
    metricName: SERVICE_HEALTH_METRIC,
    dimensions: { service, dimension, state: "healthy" },
    sampleCount: 1,
    valueSum: 1,
  }
}

test("renders grouped rolling service-health dimensions and keeps hard evidence separate", () => {
  const rollups = ["gateway", "appview", "appview-worker", "operations"].flatMap((service) => [
    sample(service, "liveness"),
    sample(service, "readiness"),
  ])
  rollups.push(sample("appview-worker", "freshness"), sample("appview-worker", "completeness"))

  render(<ServiceHealthOverTime metricRollups={rollups} />)

  expect(screen.getByText("Service Health Over Time")).toBeTruthy()
  expect(screen.getByText("Required Services Liveness")).toBeTruthy()
  expect(screen.getByText("Required Services Readiness")).toBeTruthy()
  expect(screen.getByText("Worker Freshness")).toBeTruthy()
  expect(screen.getByText("Worker Completeness")).toBeTruthy()
  expect(screen.getByText(/Hard alerts and durability remain separate evidence/i)).toBeTruthy()
  expect(screen.getAllByRole("img")).toHaveLength(1)
})

test("renders an explicit empty-evidence state", () => {
  render(<ServiceHealthOverTime metricRollups={[]} />)
  expect(screen.getByText(/No service-health samples are available/i)).toBeTruthy()
})
