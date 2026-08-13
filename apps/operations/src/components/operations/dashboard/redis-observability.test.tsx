import { describe, expect, it } from "bun:test"
import { render, screen } from "@testing-library/react"

import { RedisObservability } from "@/components/operations/dashboard/redis-observability"
import type { MetricRollup } from "@/lib/operations-types"

const duration: MetricRollup = {
  environment: "dev",
  bucketStart: "2026-08-11T12:00:00.000Z",
  metricName: "socialwire.redis.operation.duration_seconds",
  dimensions: { service: "appview", operation: "get" },
  sampleCount: 2,
  valueSum: 0.05,
  valueMax: 0.04,
}

describe("RedisObservability", () => {
  it("renders averages and maxima without a percentile label", () => {
    render(<RedisObservability metricRollups={[duration]} />)
    expect(screen.getByText("Redis Cache and Coordination")).toBeTruthy()
    expect(screen.getByText("25 ms")).toBeTruthy()
    expect(screen.getByText("40 ms")).toBeTruthy()
    expect(screen.getByText(/not percentiles/i)).toBeTruthy()
    expect(screen.queryByText(/p95/i)).toBeNull()
  })

  it("renders an explicit empty evidence state", () => {
    render(<RedisObservability metricRollups={[]} />)
    expect(screen.getByText(/No Redis evidence is available/i)).toBeTruthy()
  })
})
