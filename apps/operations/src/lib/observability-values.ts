import type { Health, MetricRollup, Overview, ServiceState } from "@/lib/operations-types"
import {
  ingestionAuthoritySource,
  isJetstreamV2InboxSource,
  jetstreamV2CheckpointForOverview,
} from "@/lib/operations-policy"

export type HealthDimension = "liveness" | "readiness" | "freshness" | "completeness"

export type HealthEvidence = {
  state: Health
  healthy: number
  total: number
}

export type RollingHealthEvidence = HealthEvidence & {
  source: "rolling" | "current"
  sampleCount: number
  windowMinutes: number
}

export const requiredOperationsServices = ["gateway", "appview", "appview-worker", "operations"] as const
export const TRANSPORT_HEARTBEAT_FRESHNESS_SECONDS = 45
export const CONNECTION_DISCONNECT_GRACE_SECONDS = 90
export const SERVICE_HEALTH_METRIC = "socialwire.service.health.samples_total"
export const SERVICE_HEALTH_WINDOW_MINUTES = 5
const SERVICE_HEALTH_SAMPLE_FLOOR = 6
const NON_HEALTHY_RATIO_THRESHOLD = 0.2

export type EffectiveConnectionState = "connected" | "disconnected" | "reconnecting" | "unknown"

export function effectiveConnectionState({
  connectionState,
  transportHeartbeatAt,
  lastDisconnectedAt,
  referenceTime,
}: {
  connectionState: EffectiveConnectionState | undefined
  transportHeartbeatAt?: string
  lastDisconnectedAt?: string
  referenceTime: string
}): EffectiveConnectionState {
  const transportAge = elapsedSeconds(transportHeartbeatAt, referenceTime)

  if (connectionState === "disconnected") {
    const disconnectAge = elapsedSeconds(lastDisconnectedAt, referenceTime)
    if (
      (disconnectAge !== null && disconnectAge <= CONNECTION_DISCONNECT_GRACE_SECONDS) ||
      (disconnectAge === null &&
        transportAge !== null &&
        transportAge <= TRANSPORT_HEARTBEAT_FRESHNESS_SECONDS)
    )
      return "reconnecting"
    return disconnectAge === null ? "unknown" : "disconnected"
  }

  if (
    transportAge === null ||
    transportAge > TRANSPORT_HEARTBEAT_FRESHNESS_SECONDS
  )
    return "unknown"

  return connectionState ?? "unknown"
}

export function boundedNonNegativeNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null
}

export function boundedNonNegativeInteger(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : null
}

export function elapsedSeconds(start: string | undefined, end: string): number | null {
  if (!start) return null
  const startMs = new Date(start).getTime()
  const endMs = new Date(end).getTime()
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs < startMs) return null
  return (endMs - startMs) / 1_000
}

export function serviceHeartbeatIsFresh(service: ServiceState, reference?: string) {
  const referenceMs = reference ? new Date(reference).getTime() : Date.now()
  const heartbeatMs = new Date(service.heartbeatAt).getTime()
  if (!Number.isFinite(referenceMs) || !Number.isFinite(heartbeatMs)) return false
  return referenceMs - heartbeatMs <= 45_000 && referenceMs >= heartbeatMs
}

export function effectiveServiceHealth(service: ServiceState, dimension: HealthDimension, reference?: string): Health {
  return serviceHeartbeatIsFresh(service, reference) ? service[dimension] : "unknown"
}

export function serviceHealthEvidence(
  services: ServiceState[],
  dimension: HealthDimension,
  reference?: string,
  requiredServices: readonly string[] = requiredOperationsServices,
): HealthEvidence {
  const states = requiredServices.map((serviceName): Health => {
    const currentInstances = services.filter(
      (service) => service.service === serviceName && serviceHeartbeatIsFresh(service, reference),
    )
    if (currentInstances.length === 0) return "unknown"
    const instanceStates = currentInstances.map((service) => service[dimension])
    if (instanceStates.some((state) => state === "unhealthy")) return "unhealthy"
    if (instanceStates.some((state) => state === "degraded")) return "degraded"
    if (instanceStates.some((state) => state === "unknown")) return "unknown"
    return "healthy"
  })
  const healthy = states.filter((state) => state === "healthy").length
  const state: Health =
    states.some((value) => value === "unhealthy")
      ? "unhealthy"
      : states.some((value) => value === "degraded")
        ? "degraded"
        : states.length === 0 || states.some((value) => value === "unknown")
          ? "unknown"
          : "healthy"
  return { state, healthy, total: states.length }
}

function rollingServiceState(
  rollups: MetricRollup[],
  service: string,
  dimension: HealthDimension,
  windowStart: number,
  windowEnd: number,
): { state: Health; sampleCount: number } {
  const samples: Record<Health, number> = { healthy: 0, degraded: 0, unhealthy: 0, unknown: 0 }
  for (const rollup of rollups) {
    if (
      rollup.metricName !== SERVICE_HEALTH_METRIC ||
      rollup.dimensions.service !== service ||
      rollup.dimensions.dimension !== dimension
    )
      continue
    const bucket = new Date(rollup.bucketStart).getTime()
    const state = rollup.dimensions.state as Health | undefined
    if (
      !Number.isFinite(bucket) ||
      bucket < windowStart ||
      bucket >= windowEnd ||
      !state ||
      !Object.prototype.hasOwnProperty.call(samples, state) ||
      !Number.isFinite(rollup.valueSum) ||
      rollup.valueSum < 0
    )
      continue
    samples[state] += rollup.valueSum
  }

  const sampleCount = Object.values(samples).reduce((total, count) => total + count, 0)
  if (sampleCount < SERVICE_HEALTH_SAMPLE_FLOOR) return { state: "unknown", sampleCount }
  if (samples.unhealthy / sampleCount >= NON_HEALTHY_RATIO_THRESHOLD)
    return { state: "unhealthy", sampleCount }
  if ((samples.unhealthy + samples.degraded) / sampleCount >= NON_HEALTHY_RATIO_THRESHOLD)
    return { state: "degraded", sampleCount }
  if (samples.unknown / sampleCount >= NON_HEALTHY_RATIO_THRESHOLD)
    return { state: "unknown", sampleCount }
  return { state: "healthy", sampleCount }
}

export function rollingServiceHealthEvidence(
  rollups: MetricRollup[],
  dimension: HealthDimension,
  reference: string,
  requiredServices: readonly string[] = requiredOperationsServices,
): RollingHealthEvidence | null {
  const referenceMs = new Date(reference).getTime()
  if (!Number.isFinite(referenceMs)) return null
  const windowEnd = Math.floor(referenceMs / 60_000) * 60_000
  const windowStart = windowEnd - SERVICE_HEALTH_WINDOW_MINUTES * 60_000
  const hasHealthSamples = rollups.some((rollup) => rollup.metricName === SERVICE_HEALTH_METRIC)
  if (!hasHealthSamples) return null

  const services = requiredServices.map((service) =>
    rollingServiceState(rollups, service, dimension, windowStart, windowEnd),
  )
  const states = services.map(({ state }) => state)
  const healthy = states.filter((state) => state === "healthy").length
  const state: Health = states.some((value) => value === "unhealthy")
    ? "unhealthy"
    : states.some((value) => value === "degraded")
      ? "degraded"
      : states.length === 0 || states.some((value) => value === "unknown")
        ? "unknown"
        : "healthy"
  return {
    state,
    healthy,
    total: states.length,
    source: "rolling",
    sampleCount: services.reduce((total, service) => total + service.sampleCount, 0),
    windowMinutes: SERVICE_HEALTH_WINDOW_MINUTES,
  }
}

export function stableServiceHealthEvidence(
  overview: Overview,
  dimension: HealthDimension,
  reference = overview.refreshedAt,
  requiredServices: readonly string[] = requiredOperationsServices,
): RollingHealthEvidence {
  return rollingServiceHealthEvidence(overview.metricRollups ?? [], dimension, reference, requiredServices) ?? {
    ...serviceHealthEvidence(overview.services, dimension, reference, requiredServices),
    source: "current",
    sampleCount: 0,
    windowMinutes: 0,
  }
}

export function healthLabel(state: Health) {
  if (state === "healthy") return "Healthy"
  if (state === "degraded") return "Degraded"
  if (state === "unhealthy") return "Unhealthy"
  return "Unknown"
}

export function overviewIngestionConnectionState(
  overview: Overview,
  reference = overview.refreshedAt,
): EffectiveConnectionState {
  const v2InboxAuthority = isJetstreamV2InboxSource(ingestionAuthoritySource(overview))
  const checkpoint = v2InboxAuthority ? jetstreamV2CheckpointForOverview(overview) : undefined
  const terminalSnapshot = checkpoint?.replayState === "snapshot_complete"
  if ((overview.ingestion && !terminalSnapshot) || !v2InboxAuthority) {
    return effectiveConnectionState({
      connectionState: overview.ingestion?.connectionState,
      transportHeartbeatAt: overview.ingestion?.transportHeartbeatAt,
      lastDisconnectedAt: overview.ingestion?.lastDisconnectAt,
      referenceTime: reference,
    })
  }

  if (!terminalSnapshot) {
    const intakeHeartbeatAge = elapsedSeconds(
      checkpoint?.intakeHeartbeatAt ?? undefined,
      reference,
    )
    if (
      intakeHeartbeatAge === null ||
      intakeHeartbeatAge > TRANSPORT_HEARTBEAT_FRESHNESS_SECONDS
    )
      return "unknown"
  }

  const evidenceValidUntil = new Date(overview.evidence.ingestion.validUntil).getTime()
  const referenceTime = new Date(reference).getTime()
  return overview.evidence.ingestion.accuracy === "exact" &&
    Number.isFinite(evidenceValidUntil) &&
    Number.isFinite(referenceTime) &&
    evidenceValidUntil >= referenceTime
    ? "connected"
    : "unknown"
}

export function overallSystemHealth(overview: Overview, reference = overview.refreshedAt): Health {
  const states = [
    stableServiceHealthEvidence(overview, "liveness", reference).state,
    stableServiceHealthEvidence(overview, "readiness", reference).state,
    stableServiceHealthEvidence(overview, "freshness", reference, ["appview-worker"]).state,
    stableServiceHealthEvidence(overview, "completeness", reference, ["appview-worker"]).state,
  ]
  const v2InboxAuthority = isJetstreamV2InboxSource(ingestionAuthoritySource(overview))
  const connectionState = overviewIngestionConnectionState(overview, reference)
  const checkpoint = v2InboxAuthority
    ? jetstreamV2CheckpointForOverview(overview)
    : overview.durability?.checkpoints[0]
  const recoveryActive =
    checkpoint?.replayState === "replaying" ||
    checkpoint?.replayState === "paused_budget" ||
    (overview.durability?.incidents.recovering ?? 0) > 0
  const oldestInboxAge = overview.durability?.inbox.oldestPendingAgeSeconds
  const durabilityRisk = overview.durability
    ? overview.durability.incidents.open > 0 ||
      overview.durability.incidents.recovering > 0 ||
      overview.durability.incidents.verificationRequired > 0 ||
      overview.durability.inbox.deadLetters > 0 ||
      (oldestInboxAge !== undefined && oldestInboxAge >= (recoveryActive ? 900 : 60))
    : overview.counts.activeGaps > 0
  if (
    connectionState === "disconnected" ||
    overview.alerts.some((alert) => alert.status === "open" && alert.severity === "critical") ||
    states.includes("unhealthy")
  )
    return "unhealthy"
  if (
    connectionState === "reconnecting" ||
    durabilityRisk ||
    overview.counts.unresolvedAlerts > 0 ||
    states.includes("degraded")
  )
    return "degraded"
  if ((!overview.ingestion && !v2InboxAuthority) || connectionState === "unknown" || states.includes("unknown"))
    return "unknown"
  return "healthy"
}
