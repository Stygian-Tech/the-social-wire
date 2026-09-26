import type { ServiceState } from "@/lib/operations-types"

export const LEGACY_APPVIEW_WORKER = "appview-worker"
export const PROJECTION_APPVIEW_SERVICE = "projection-pool-appview"
export const COORDINATOR_APPVIEW_SERVICE = "coordinator-appview"
export const APPVIEW_COORDINATOR_ROLE = "indexing.appview-coordinator"

export function hasConsolidatedWorkerEvidence(serviceNames: readonly string[]) {
  return serviceNames.some((name) =>
    name === PROJECTION_APPVIEW_SERVICE || name === COORDINATOR_APPVIEW_SERVICE,
  )
}

export function hasActiveCoordinatorAuthority(evidence: Record<string, string>) {
  return evidence.coordinator_authority === "active" &&
    evidence.coordinator_role === APPVIEW_COORDINATOR_ROLE
}

/** Legacy worker is a logical coverage slot during the service handoff. */
export function requiredWorkerServices(
  requiredServices: readonly string[],
  dimension: string,
  observedServices: readonly string[],
): string[] {
  if (!hasConsolidatedWorkerEvidence(observedServices)) return [...requiredServices]
  return [...new Set(requiredServices.flatMap((service) => service === LEGACY_APPVIEW_WORKER
    ? dimension === "freshness"
      ? [PROJECTION_APPVIEW_SERVICE]
      : [PROJECTION_APPVIEW_SERVICE, COORDINATOR_APPVIEW_SERVICE]
    : [service]))]
}

export function currentIngestionWorker(services: ServiceState[]) {
  const name = hasConsolidatedWorkerEvidence(services.map((service) => service.service))
    ? PROJECTION_APPVIEW_SERVICE
    : LEGACY_APPVIEW_WORKER
  // A stale/missing consolidated role must never select a healthy legacy
  // worker instead. Health/freshness is evaluated separately by its evidence.
  return services.filter((service) => service.service === name)
    .sort((left, right) => Date.parse(right.heartbeatAt) - Date.parse(left.heartbeatAt))[0]
}
