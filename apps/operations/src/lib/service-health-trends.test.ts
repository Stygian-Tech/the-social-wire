import { describe, expect, it } from "bun:test"

import { SERVICE_HEALTH_METRIC } from "@/lib/observability-values"
import type { MetricRollup } from "@/lib/operations-types"
import {
  latestServiceHealthPercentages,
  serviceHealthRollingTrends,
} from "@/lib/service-health-trends"

const requiredServices = ["gateway", "appview", "appview-worker", "operations"]

function sample(
  minute: number,
  service: string,
  dimension: string,
  state: string,
  valueSum = 1,
): MetricRollup {
  return {
    environment: "dev",
    bucketStart: new Date(Date.parse("2026-08-20T12:00:00Z") + minute * 60_000).toISOString(),
    metricName: SERVICE_HEALTH_METRIC,
    dimensions: { service, dimension, state },
    sampleCount: valueSum,
    valueSum,
  }
}

describe("serviceHealthRollingTrends", () => {
  it("calculates a weighted five-minute healthy percentage for the intended service scopes", () => {
    const rollups: MetricRollup[] = []
    for (let minute = 0; minute < 5; minute += 1) {
      for (const service of requiredServices) {
        rollups.push(sample(minute, service, "liveness", minute === 4 && service === "appview" ? "degraded" : "healthy"))
        rollups.push(sample(minute, service, "readiness", "healthy"))
      }
      rollups.push(sample(minute, "appview-worker", "freshness", "healthy"))
      rollups.push(sample(minute, "appview-worker", "completeness", "healthy"))
      rollups.push(sample(minute, "unrelated", "liveness", "unhealthy", 100))
    }

    const latest = latestServiceHealthPercentages(serviceHealthRollingTrends(rollups))
    expect(latest).toMatchObject({
      liveness: 95,
      readiness: 100,
      freshness: 100,
      completeness: 100,
    })
  })

  it("keeps a bucket missing when a required service did not report in that minute", () => {
    const rollups = requiredServices
      .filter((service) => service !== "gateway")
      .map((service) => sample(0, service, "liveness", "healthy"))

    expect(serviceHealthRollingTrends(rollups)[0]?.liveness).toBeNull()
  })

  it("ignores malformed and unrelated metrics", () => {
    const unrelated = sample(0, "gateway", "liveness", "healthy")
    unrelated.metricName = "other.metric"
    expect(serviceHealthRollingTrends([unrelated])).toEqual([])
  })
})
