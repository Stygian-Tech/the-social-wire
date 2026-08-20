import {
  requiredOperationsServices,
  SERVICE_HEALTH_METRIC,
  SERVICE_HEALTH_WINDOW_MINUTES,
  type HealthDimension,
} from "@/lib/observability-values"
import type { MetricRollup } from "@/lib/operations-types"

export type ServiceHealthTrendPoint = {
  timestamp: number
  liveness: number | null
  readiness: number | null
  freshness: number | null
  completeness: number | null
}

const healthStates = new Set(["healthy", "degraded", "unhealthy", "unknown"])
const targetServices: Record<HealthDimension, readonly string[]> = {
  liveness: requiredOperationsServices,
  readiness: requiredOperationsServices,
  freshness: ["appview-worker"],
  completeness: ["appview-worker"],
}

type HealthSample = {
  timestamp: number
  dimension: HealthDimension
  service: string
  state: string
  value: number
}

function samplesFromRollups(rollups: MetricRollup[]): HealthSample[] {
  return rollups.flatMap((rollup) => {
    if (rollup.metricName !== SERVICE_HEALTH_METRIC) return []
    const timestamp = new Date(rollup.bucketStart).getTime()
    const dimension = rollup.dimensions.dimension as HealthDimension | undefined
    const service = rollup.dimensions.service
    const state = rollup.dimensions.state
    if (
      !Number.isFinite(timestamp) ||
      !dimension ||
      !(dimension in targetServices) ||
      !service ||
      !state ||
      !healthStates.has(state) ||
      !Number.isFinite(rollup.valueSum) ||
      rollup.valueSum < 0
    )
      return []
    return [{ timestamp, dimension, service, state, value: rollup.valueSum }]
  })
}

function rollingHealthyPercentage(
  samples: HealthSample[],
  timestamp: number,
  dimension: HealthDimension,
): number | null {
  const services = targetServices[dimension]
  const currentServices = new Set(
    samples
      .filter((sample) =>
        sample.timestamp === timestamp &&
        sample.dimension === dimension &&
        services.includes(sample.service),
      )
      .map((sample) => sample.service),
  )
  if (services.some((service) => !currentServices.has(service))) return null

  const windowStart = timestamp - (SERVICE_HEALTH_WINDOW_MINUTES - 1) * 60_000
  let healthy = 0
  let total = 0
  for (const sample of samples) {
    if (
      sample.timestamp < windowStart ||
      sample.timestamp > timestamp ||
      sample.dimension !== dimension ||
      !services.includes(sample.service)
    )
      continue
    total += sample.value
    if (sample.state === "healthy") healthy += sample.value
  }
  return total > 0 ? (healthy / total) * 100 : null
}

export function serviceHealthRollingTrends(rollups: MetricRollup[]): ServiceHealthTrendPoint[] {
  const samples = samplesFromRollups(rollups)
  if (samples.length === 0) return []
  const start = Math.min(...samples.map(({ timestamp }) => timestamp))
  const end = Math.max(...samples.map(({ timestamp }) => timestamp))

  return Array.from({ length: Math.floor((end - start) / 60_000) + 1 }, (_, index) => {
    const timestamp = start + index * 60_000
    return {
      timestamp,
      liveness: rollingHealthyPercentage(samples, timestamp, "liveness"),
      readiness: rollingHealthyPercentage(samples, timestamp, "readiness"),
      freshness: rollingHealthyPercentage(samples, timestamp, "freshness"),
      completeness: rollingHealthyPercentage(samples, timestamp, "completeness"),
    }
  })
}

export function latestServiceHealthPercentages(points: ServiceHealthTrendPoint[]) {
  return points.at(-1) ?? null
}
