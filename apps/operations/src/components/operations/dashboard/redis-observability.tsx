import { DatabaseZap } from "lucide-react"

import { OperationsSection } from "@/components/operations/operations-section"
import { Badge } from "@/components/ui/badge"
import type { MetricRollup } from "@/lib/operations-types"
import { redisOperationsSummary } from "@/lib/redis-metrics"

const number = (value: number | null, digits = 1) =>
  value === null ? "—" : value.toLocaleString(undefined, { maximumFractionDigits: digits })

const bytes = (value: number | null) => {
  if (value === null) return "—"
  if (value < 1_000_000) return `${number(value / 1_000)} KB`
  return `${number(value / 1_000_000)} MB`
}

export function RedisObservability({ metricRollups }: { metricRollups: MetricRollup[] }) {
  const summary = redisOperationsSummary(metricRollups)
  const lookupTotal = Object.values(summary.lookups).reduce((total, value) => total + value, 0)
  const unreadReasons = Object.entries(summary.unreadRecomputes).sort(([left], [right]) => left.localeCompare(right))

  return (
    <OperationsSection
      title={<span className="flex items-center gap-2"><DatabaseZap className="size-3.5" /> Redis Cache and Coordination</span>}
      description="Deidentified Redis cache, lock, circuit, and resource evidence. Durations are averages and maxima, not percentiles."
      action={<Badge tone={summary.errors === 0 ? "success" : "warning"}>{summary.errors.toLocaleString()} errors</Badge>}
    >
      {lookupTotal === 0 && summary.operationSamples === 0 ? (
        <p className="p-6 text-center text-xs text-muted-foreground">
          No Redis evidence is available in the retained metrics window.
        </p>
      ) : (
        <div className="grid gap-3 p-3 xl:grid-cols-2">
          <MetricGroup title="Cache Lookups">
            <Metric label="Fresh" value={number(summary.lookups.fresh, 0)} />
            <Metric label="Stale" value={number(summary.lookups.stale, 0)} />
            <Metric label="Miss" value={number(summary.lookups.miss, 0)} />
            <Metric label="Malformed" value={number(summary.lookups.malformed, 0)} />
            <Metric label="Fallback" value={number(summary.lookups.fallback, 0)} />
          </MetricGroup>
          <MetricGroup title="Redis Operations">
            <Metric label="Average Duration" value={`${number(summary.averageOperationMilliseconds)} ms`} />
            <Metric label="Maximum Duration" value={`${number(summary.maximumOperationMilliseconds)} ms`} />
            <Metric label="Samples" value={number(summary.operationSamples, 0)} />
            <Metric label="Circuit Open Samples" value={number(summary.circuitOpenSamples, 0)} />
          </MetricGroup>
          <MetricGroup title="Coordination">
            <Metric label="Locks Acquired" value={number(summary.locksAcquired, 0)} />
            <Metric label="Lock Contention" value={number(summary.lockContention, 0)} />
            <Metric label="Unread Recomputation" value={number(unreadReasons.reduce((total, [, value]) => total + value, 0), 0)} />
            <Metric label="Recompute Reasons" value={unreadReasons.map(([reason, value]) => `${reason}: ${value}`).join(", ") || "—"} />
          </MetricGroup>
          <MetricGroup title="Redis Resources">
            <Metric label="Expired Keys" value={number(summary.expiredKeys, 0)} />
            <Metric label="Evicted Keys" value={number(summary.evictedKeys, 0)} />
            <Metric label="Memory Used" value={bytes(summary.memoryUsedBytes)} />
          </MetricGroup>
        </div>
      )}
    </OperationsSection>
  )
}

function MetricGroup({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <article className="min-w-0 rounded-md border bg-muted/10 p-3">
      <h3 className="mb-3 text-xs font-semibold">{title}</h3>
      <dl className="grid grid-cols-2 gap-3 sm:grid-cols-3">{children}</dl>
    </article>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-[9px] text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words font-mono text-sm font-medium">{value}</dd>
    </div>
  )
}
