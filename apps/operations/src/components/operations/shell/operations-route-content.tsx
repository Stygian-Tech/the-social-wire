import { AlertsTable } from "@/components/operations/dashboard/alerts-table"
import { CapabilityStatus } from "@/components/operations/dashboard/capability-status"
import { BackfillsTable } from "@/components/operations/backfills/backfills-table"
import { CollectionHealth } from "@/components/operations/dashboard/collection-health"
import { CollectionTable } from "@/components/operations/dashboard/collection-table"
import { DatabaseObservability } from "@/components/operations/dashboard/database-observability"
import { EvidenceInventory } from "@/components/operations/dashboard/evidence-inventory"
import { EndpointInventory } from "@/components/operations/dashboard/endpoint-inventory"
import { GapsTable } from "@/components/operations/gaps/gaps-table"
import { HealthStrip } from "@/components/operations/dashboard/health-strip"
import { LiveStream } from "@/components/operations/dashboard/live-stream"
import { OperationsCommandsTable } from "@/components/operations/dashboard/operations-commands-table"
import { RequestTable } from "@/components/operations/dashboard/request-table"
import { Runbooks } from "@/components/operations/runbooks"
import { ServiceTable } from "@/components/operations/dashboard/service-table"
import { TraceDetail } from "@/components/operations/traces/trace-detail"
import type { Runbook } from "@/components/operations/shell/operations-view-types"
import { metricWindowReference } from "@/lib/collection-metrics"
import type { EnvironmentName, Gap, Overview } from "@/lib/operations-types"

export function OperationsRouteContent({
  current,
  traceId,
  lifecycleView,
  data,
  environment,
  runbooks,
  onSelectGap,
  onInvestigateGap,
  recoveryEnabled,
  operatorMutationsEnabled,
  referenceTime,
}: {
  current: string
  traceId?: string
  lifecycleView?: string
  data: Overview
  environment: EnvironmentName
  runbooks: Runbook[]
  onSelectGap: (gap: Gap) => void
  onInvestigateGap: (gap: Gap) => void
  recoveryEnabled: boolean
  operatorMutationsEnabled: boolean
  referenceTime: string
}) {
  const metricsGeneratedAt = metricWindowReference(data.refreshedAt, data.evidence.metrics)
  if (current === "ingestion")
    return (
      <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-3">
        <LiveStream data={data} environment={environment} mutationsEnabled={recoveryEnabled} referenceTime={referenceTime} />
        <CollectionTable
          metricRollups={data.metricRollups ?? []}
          refreshedAt={metricsGeneratedAt}
          evidence={data.evidence.metrics}
          referenceTime={referenceTime}
        />
        <GapsTable
          gaps={data.gaps ?? []}
          backfills={data.backfills ?? []}
          onSelect={onSelectGap}
          onInvestigate={onInvestigateGap}
          mutationsEnabled={recoveryEnabled}
          counts={data.counts}
        />
      </div>
    )
  if (current === "appview")
    return (
      <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-3">
        <RequestTable spans={data.recentTraces ?? []} refreshedAt={data.refreshedAt} expanded />
        <DatabaseObservability overview={data} referenceTime={referenceTime} />
        <ServiceTable data={data} referenceTime={referenceTime} />
      </div>
    )
  if (current === "gaps")
    return (
      <GapsTable
        gaps={data.gaps ?? []}
        backfills={data.backfills ?? []}
        onSelect={onSelectGap}
        onInvestigate={onInvestigateGap}
        expanded
        mutationsEnabled={recoveryEnabled}
        counts={data.counts}
        view={lifecycleView === "history" ? "history" : "active"}
      />
    )
  if (current === "backfills")
    return (
      <BackfillsTable
        backfills={data.backfills ?? []}
        environment={environment}
        expanded
        mutationsEnabled={recoveryEnabled}
        counts={data.counts}
        view={
          lifecycleView === "needs_attention" || lifecycleView === "history"
            ? lifecycleView
            : "active"
        }
      />
    )
  if (current === "alerts")
    return (
      <AlertsTable
        data={data}
        environment={environment}
        mutationsEnabled={operatorMutationsEnabled}
        view={lifecycleView === "history" ? "history" : "active"}
      />
    )
  if (current === "commands") return <OperationsCommandsTable commands={data.commands ?? []} />
  if (current === "endpoints")
    return <EndpointInventory endpoints={data.jetstreamEndpoints ?? []} referenceTime={referenceTime} />
  if (current === "runbooks") return <Runbooks runbooks={runbooks} />
  if (current === "traces")
    return <TraceDetail traceId={traceId} />
  return (
    <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-3">
      <HealthStrip overview={data} referenceTime={referenceTime} />
      <CapabilityStatus overview={data} />
      <EvidenceInventory overview={data} referenceTime={referenceTime} />
      <LiveStream data={data} environment={environment} mutationsEnabled={recoveryEnabled} referenceTime={referenceTime} />
      <CollectionTable
        metricRollups={data.metricRollups ?? []}
        refreshedAt={metricsGeneratedAt}
        evidence={data.evidence.metrics}
        referenceTime={referenceTime}
      />
      <DatabaseObservability overview={data} referenceTime={referenceTime} />
      <CollectionHealth
        metricRollups={data.metricRollups ?? []}
        refreshedAt={metricsGeneratedAt}
        evidence={data.evidence.metrics}
        referenceTime={referenceTime}
      />
    </div>
  )
}
