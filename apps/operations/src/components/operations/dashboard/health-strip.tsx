import { Activity, CheckCircle2, Clock3, Database, TriangleAlert } from "lucide-react"
import {
  elapsedSeconds,
  healthLabel,
  overviewIngestionConnectionState,
  serviceHealthEvidence,
} from "@/lib/observability-values"
import {
  ingestionAuthoritySource,
  ingestionSourceLabel,
  isJetstreamV2InboxSource,
  jetstreamV2CheckpointForOverview,
} from "@/lib/operations-policy"
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
  const authoritySource = ingestionAuthoritySource(overview)
  const v2InboxAuthority = isJetstreamV2InboxSource(authoritySource)
  const authorityLabel = authoritySource
    ? (v2InboxAuthority ? ingestionSourceLabel(authoritySource) : authoritySource)
    : "Ingestion source"
  const durabilityCheckpoint = v2InboxAuthority
    ? jetstreamV2CheckpointForOverview(overview)
    : overview.durability?.checkpoints[0]
  const transportAge = elapsedSeconds(
    overview.ingestion?.transportHeartbeatAt ??
      (v2InboxAuthority ? durabilityCheckpoint?.intakeHeartbeatAt ?? undefined : undefined),
    referenceTime,
  )
  const connectionState = overviewIngestionConnectionState(overview, referenceTime)
  const legacyGapSignals =
    overview.counts?.activeGaps ?? (overview.gaps ?? []).filter((gap) => !["resolved", "ignored"].includes(gap.status)).length
  const durability = overview.durability
  const openIncidents = durability
    ? durability.incidents.open + durability.incidents.recovering + durability.incidents.verificationRequired
    : null
  const deadLetters = durability?.inbox.deadLetters ?? null
  const oldestInboxAge = durability?.inbox.oldestPendingAgeSeconds
  const recoveryActive =
    durabilityCheckpoint?.replayState === "replaying" ||
    durabilityCheckpoint?.replayState === "paused_budget" ||
    (durability?.incidents.recovering ?? 0) > 0
  const inboxAgeBudgetSeconds = recoveryActive ? 900 : 60
  const durabilityHealthy =
    durability !== undefined &&
    openIncidents === 0 &&
    deadLetters === 0 &&
    (oldestInboxAge === undefined || oldestInboxAge < inboxAgeBudgetSeconds)
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
  const projectionsComplete =
    projectionCompleteness.state === "healthy" &&
    (durability ? durabilityHealthy : legacyGapSignals === 0)
  const completenessNote = durability
    ? `${openIncidents} open recovery incidents · staged ${durabilityCheckpoint?.lastStagedSequence?.toLocaleString() ?? "—"} / terminal prefix ${durabilityCheckpoint?.lastAppliedSequence?.toLocaleString() ?? "—"} · oldest inbox ${oldestInboxAge === undefined ? "—" : `${oldestInboxAge.toFixed(1)}s`} (${inboxAgeBudgetSeconds}s ${recoveryActive ? "recovery" : "normal"} budget) · ${deadLetters} unresolved dead letters`
    : `${legacyGapSignals} legacy gap signals · ${projectionCompleteness.healthy} / ${projectionCompleteness.total} Charybdis projections complete`
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
          ? `No valid ${v2InboxAuthority ? "durable checkpoint" : "transport heartbeat"} reported`
          : `${authorityLabel} ${v2InboxAuthority ? "checkpoint" : "transport heartbeat"} ${transportAge.toFixed(1)}s ago · Charybdis freshness ${workerFreshness.state}`,
      icon: Clock3,
      warning: !ingestionFresh,
    },
    {
      label: "Projection Completeness",
      value: projectionsComplete ? "Complete" : projectionCompleteness.state === "unknown" ? "Unknown" : "At Risk",
      note: completenessNote,
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
