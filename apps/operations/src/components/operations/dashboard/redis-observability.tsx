import { DatabaseZap } from "lucide-react"

import {
  GroupedEvidenceChart,
  type GroupedChartDatum,
} from "@/components/operations/dashboard/grouped-evidence-chart"
import { OperationsSection } from "@/components/operations/operations-section"
import { OperationsEmptyState } from "@/components/operations/operations-empty-state"
import { Badge } from "@/components/ui/badge"
import type { MetricRollup } from "@/lib/operations-types"
import { redisOperationsSummary, redisOperationsTrends } from "@/lib/redis-metrics"

const integer = (value: number) => value.toLocaleString(undefined, { maximumFractionDigits: 0 })
const milliseconds = (value: number) => `${value.toLocaleString(undefined, { maximumFractionDigits: 1 })} ms`
const bytes = (value: number) => {
  if (value < 1_000_000) return `${(value / 1_000).toLocaleString(undefined, { maximumFractionDigits: 1 })} KB`
  return `${(value / 1_000_000).toLocaleString(undefined, { maximumFractionDigits: 1 })} MB`
}

export function RedisObservability({ metricRollups }: { metricRollups: MetricRollup[] }) {
  const summary = redisOperationsSummary(metricRollups)
  const trends = redisOperationsTrends(metricRollups) as unknown as GroupedChartDatum[]
  const hasEvidence = trends.some((point) =>
    Object.entries(point).some(([key, value]) => key !== "timestamp" && value !== null),
  )

  return (
    <OperationsSection
      title={<span className="flex items-center gap-2"><DatabaseZap className="size-3.5" /> Redis Cache and Coordination</span>}
      description="Deidentified Redis cache, lock, circuit, and resource evidence over time. Durations are averages and maxima, not percentiles."
      action={<Badge tone={summary.errors === 0 ? "success" : "warning"}>{summary.errors.toLocaleString()} errors</Badge>}
    >
      {!hasEvidence ? (
        <OperationsEmptyState>No Redis evidence is available in the retained metrics window.</OperationsEmptyState>
      ) : (
        <div className="grid gap-3 p-3 xl:grid-cols-2">
          <GroupedEvidenceChart
            title="Cache Lookup Outcomes"
            description="Fresh, stale, missed, malformed, and fallback outcomes per closed minute"
            unit="lookups / minute"
            source="Operations metric rollups"
            data={trends}
            series={[
              { key: "freshLookups", label: "Fresh", color: "var(--success)" },
              { key: "staleLookups", label: "Stale", color: "var(--warning)" },
              { key: "missedLookups", label: "Missed", color: "var(--primary)" },
              { key: "malformedLookups", label: "Malformed", color: "var(--destructive)", dashed: true },
              { key: "fallbackLookups", label: "Fallback", color: "var(--info)", dashed: true },
            ]}
            valueFormatter={integer}
          />
          <GroupedEvidenceChart
            title="Redis Operation Duration"
            description="Average and maximum operation duration by closed minute"
            unit="milliseconds"
            source="Operations metric rollups"
            data={trends}
            series={[
              { key: "averageOperationMilliseconds", label: "Average", color: "var(--primary)" },
              { key: "maximumOperationMilliseconds", label: "Maximum", color: "var(--warning)", dashed: true },
            ]}
            valueFormatter={milliseconds}
            sampleCount={summary.operationSamples}
          />
          <GroupedEvidenceChart
            title="Redis Coordination Activity"
            description="Lock, circuit, error, and unread-recomputation activity per closed minute"
            unit="events / minute"
            source="Operations metric rollups"
            data={trends}
            series={[
              { key: "locksAcquired", label: "Locks Acquired", color: "var(--success)" },
              { key: "lockContention", label: "Lock Contention", color: "var(--warning)" },
              { key: "unreadRecomputes", label: "Unread Recomputation", color: "var(--primary)" },
              { key: "circuitOpenSamples", label: "Circuit Open", color: "var(--info)", dashed: true },
              { key: "errors", label: "Errors", color: "var(--destructive)", dashed: true },
            ]}
            valueFormatter={integer}
          />
          <GroupedEvidenceChart
            title="Redis Key Pressure"
            description="Expired and evicted key gauges by closed minute"
            unit="keys"
            source="Operations metric rollups"
            data={trends}
            series={[
              { key: "expiredKeys", label: "Expired", color: "var(--primary)" },
              { key: "evictedKeys", label: "Evicted", color: "var(--warning)", dashed: true },
            ]}
            valueFormatter={integer}
          />
          <div className="xl:col-span-2">
            <GroupedEvidenceChart
              title="Redis Memory Used"
              description="Maximum reported memory use by closed minute"
              unit="bytes"
              source="Operations metric rollups"
              data={trends}
              series={[{ key: "memoryUsedBytes", label: "Memory Used", color: "var(--primary)" }]}
              valueFormatter={bytes}
            />
          </div>
        </div>
      )}
    </OperationsSection>
  )
}
