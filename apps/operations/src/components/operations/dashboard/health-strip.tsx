import { Activity, CheckCircle2, Clock3, Database, TriangleAlert } from "lucide-react"
import {
  effectiveConnectionState,
  elapsedSeconds,
  healthLabel,
  serviceHealthEvidence,
} from "@/lib/observability-values"
import type { Overview } from "@/lib/operations-types"

export function HealthStrip({ overview, referenceTime = overview.refreshedAt }: { overview: Overview; referenceTime?: string }) {
  const liveness = serviceHealthEvidence(overview.services, "liveness", referenceTime)
  const readiness = serviceHealthEvidence(overview.services, "readiness", referenceTime)
  const ingestionWorkers = overview.services.filter((service) => service.service.toLowerCase().includes("worker"))
  const workerFreshness = serviceHealthEvidence(ingestionWorkers, "freshness", referenceTime, ["appview-worker"])
  const projectionCompleteness = serviceHealthEvidence(
    ingestionWorkers,
    "completeness",
    referenceTime,
    ["appview-worker"],
  )
  const transportAge = elapsedSeconds(
    overview.ingestion?.transportHeartbeatAt,
    referenceTime,
  )
  const connectionState = effectiveConnectionState({
    connectionState: overview.ingestion?.connectionState,
    transportHeartbeatAt: overview.ingestion?.transportHeartbeatAt,
    lastDisconnectedAt: overview.ingestion?.lastDisconnectAt,
    referenceTime,
  })
  const activeGaps =
    overview.counts?.activeGaps ?? (overview.gaps ?? []).filter((gap) => !["resolved", "ignored"].includes(gap.status)).length
  const ingestionFresh =
    connectionState === "connected" &&
    workerFreshness.state === "healthy"
  const freshnessLabel =
    connectionState === "disconnected"
        ? "Disconnected"
        : connectionState === "reconnecting"
          ? "Reconnecting"
        : connectionState === "unknown"
          ? "Unknown"
        : workerFreshness.state !== "healthy"
          ? healthLabel(workerFreshness.state)
          : "Good"
  const projectionsComplete = projectionCompleteness.state === "healthy" && activeGaps === 0
  const items = [
    {
      label: "Service Liveness",
      value: healthLabel(liveness.state),
      note: `${liveness.healthy} / ${liveness.total} required services report healthy`,
      icon: Activity,
      warning: liveness.state !== "healthy",
    },
    {
      label: "Traffic Readiness",
      value: readiness.state === "healthy" ? "Ready" : healthLabel(readiness.state),
      note: `${readiness.healthy} / ${readiness.total} required services report ready`,
      icon: CheckCircle2,
      warning: readiness.state !== "healthy",
    },
    {
      label: "Ingestion Freshness",
      value: freshnessLabel,
      note:
        transportAge === null
          ? "No valid transport heartbeat reported"
          : `${overview.ingestion?.source ?? "Ingestion source"} transport heartbeat ${transportAge.toFixed(1)}s ago · worker freshness ${workerFreshness.state}`,
      icon: Clock3,
      warning: !ingestionFresh,
    },
    {
      label: "Projection Completeness",
      value: projectionsComplete ? "Complete" : projectionCompleteness.state === "unknown" ? "Unknown" : "At Risk",
      note: `${activeGaps} active gaps · ${projectionCompleteness.healthy} / ${projectionCompleteness.total} projection workers complete`,
      icon: Database,
      warning: !projectionsComplete,
    },
  ]
  return (
    <section
      className="ops-panel grid divide-y sm:grid-cols-2 sm:divide-x sm:divide-y-0 xl:grid-cols-4"
      aria-label="System Health"
    >
      {items.map((item) => (
        <div key={item.label} className="relative min-w-0 p-3">
          <div className="flex items-center gap-2 text-[11px]">
            <item.icon className="size-3.5" />
            {item.label}
          </div>
          <p className={`mt-1 text-sm font-medium ${item.warning ? "ops-warning" : "ops-success"}`}>{item.value}</p>
          <p className="mt-1 text-[10px] text-muted-foreground">{item.note}</p>
          {item.warning ? <TriangleAlert className="absolute right-3 top-3 size-3.5 ops-warning" /> : null}
        </div>
      ))}
    </section>
  )
}
