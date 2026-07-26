import type { Health, Overview, ServiceState } from "@/lib/operations-types"

export type HealthDimension = "liveness" | "readiness" | "freshness" | "completeness"

export type HealthEvidence = {
  state: Health
  healthy: number
  total: number
}

export const requiredOperationsServices = ["gateway", "appview", "appview-worker", "operations"] as const
export const TRANSPORT_HEARTBEAT_FRESHNESS_SECONDS = 45
export const CONNECTION_DISCONNECT_GRACE_SECONDS = 90

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

export function healthLabel(state: Health) {
  if (state === "healthy") return "Healthy"
  if (state === "degraded") return "Degraded"
  if (state === "unhealthy") return "Unhealthy"
  return "Unknown"
}

export function overallSystemHealth(overview: Overview, reference = overview.refreshedAt): Health {
  const states = [
    serviceHealthEvidence(overview.services, "liveness", reference).state,
    serviceHealthEvidence(overview.services, "readiness", reference).state,
    serviceHealthEvidence(overview.services, "freshness", reference, ["appview-worker"]).state,
    serviceHealthEvidence(overview.services, "completeness", reference, ["appview-worker"]).state,
  ]
  const connectionState = effectiveConnectionState({
    connectionState: overview.ingestion?.connectionState,
    transportHeartbeatAt: overview.ingestion?.transportHeartbeatAt,
    lastDisconnectedAt: overview.ingestion?.lastDisconnectAt,
    referenceTime: reference,
  })
  if (
    connectionState === "disconnected" ||
    overview.alerts.some((alert) => alert.status === "open" && alert.severity === "critical") ||
    states.includes("unhealthy")
  )
    return "unhealthy"
  if (
    connectionState === "reconnecting" ||
    overview.counts.activeGaps > 0 ||
    overview.counts.unresolvedAlerts > 0 ||
    states.includes("degraded")
  )
    return "degraded"
  if (!overview.ingestion || connectionState === "unknown" || states.includes("unknown")) return "unknown"
  return "healthy"
}
