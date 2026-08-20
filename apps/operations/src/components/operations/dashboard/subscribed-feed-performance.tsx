import { Gauge } from "lucide-react"

import {
  GroupedEvidenceChart,
  type GroupedChartDatum,
} from "@/components/operations/dashboard/grouped-evidence-chart"
import { OperationsSection } from "@/components/operations/operations-section"
import { OperationsEmptyState } from "@/components/operations/operations-empty-state"
import { Badge } from "@/components/ui/badge"
import {
  subscribedFeedPerformanceRows,
  subscribedFeedPerformanceTrends,
} from "@/lib/subscribed-feed-metrics"
import type { MetricRollup } from "@/lib/operations-types"

const formatNumber = (value: number | null, maximumFractionDigits = 1) =>
  value === null
    ? "—"
    : value.toLocaleString(undefined, { maximumFractionDigits })

const formatBytes = (value: number | null) => {
  if (value === null) return "—"
  if (value < 1_000) return `${Math.round(value)} B`
  return `${(value / 1_000).toLocaleString(undefined, { maximumFractionDigits: 1 })} KB`
}

export function SubscribedFeedPerformance({
  metricRollups,
}: {
  metricRollups: MetricRollup[]
}) {
  const rows = subscribedFeedPerformanceRows(metricRollups)
  const trends = subscribedFeedPerformanceTrends(metricRollups) as unknown as GroupedChartDatum[]
  const sampleCount = rows.reduce((total, row) => total + row.requestSamples, 0)

  return (
    <OperationsSection
      title={<span className="flex items-center gap-2"><Gauge className="size-3.5" /> Subscribed Feed Performance</span>}
      description="Observed AppView aggregate-feed rollups from the closed 15-minute window. Values are averages and maxima, not percentiles."
      action={<Badge tone={sampleCount > 0 ? "success" : "neutral"}>n={sampleCount.toLocaleString()}</Badge>}
    >
      {rows.length === 0 ? (
        <OperationsEmptyState>No Subscribed-feed performance samples are available in the retained window.</OperationsEmptyState>
      ) : (
        <div className="grid gap-3 p-3 xl:grid-cols-2">
          <GroupedEvidenceChart
            data={trends}
            series={[
              { key: "firstPageAverageQueryMilliseconds", label: "First Page Average", color: "var(--primary)" },
              { key: "firstPageMaximumQueryMilliseconds", label: "First Page Maximum", color: "var(--primary)", dashed: true },
              { key: "paginationAverageQueryMilliseconds", label: "Pagination Average", color: "var(--info)" },
              { key: "paginationMaximumQueryMilliseconds", label: "Pagination Maximum", color: "var(--warning)", dashed: true },
            ]}
            title="Query Duration"
            description="First-page and pagination average/maximum by closed bucket; maxima are not percentiles"
            unit="milliseconds"
            source="AppView subscribed-feed rollups"
            valueFormatter={(value) => `${formatNumber(value)} ms`}
            sampleCount={sampleCount}
          />
          <GroupedEvidenceChart
            data={trends}
            series={[
              { key: "firstPageAverageRowsScanned", label: "First Page Scanned", color: "var(--warning)" },
              { key: "firstPageAverageRowsReturned", label: "First Page Returned", color: "var(--success)" },
              { key: "paginationAverageRowsScanned", label: "Pagination Scanned", color: "var(--info)" },
              { key: "paginationAverageRowsReturned", label: "Pagination Returned", color: "var(--primary)" },
            ]}
            title="Rows Scanned and Returned"
            description="Average query scan work and result yield by page kind"
            unit="rows per request"
            source="AppView subscribed-feed rollups"
            valueFormatter={(value) => formatNumber(value)}
            sampleCount={sampleCount}
          />
          <GroupedEvidenceChart
            data={trends}
            series={[
              { key: "firstPageAveragePayloadBytes", label: "First Page", color: "var(--primary)" },
              { key: "paginationAveragePayloadBytes", label: "Pagination", color: "var(--info)" },
            ]}
            title="Encoded Payload Size"
            description="Average encoded response payload by page kind"
            unit="bytes per request"
            source="AppView subscribed-feed rollups"
            valueFormatter={formatBytes}
            sampleCount={sampleCount}
          />
          <GroupedEvidenceChart
            data={trends}
            series={[
              { key: "firstPageDuplicatesSuppressed", label: "First Page", color: "var(--warning)" },
              { key: "paginationDuplicatesSuppressed", label: "Pagination", color: "var(--info)" },
            ]}
            title="Canonical Duplicates Suppressed"
            description="Deduplication work by page kind and closed bucket"
            unit="duplicates per minute"
            source="AppView subscribed-feed rollups"
            valueFormatter={(value) => formatNumber(value, 0)}
            sampleCount={sampleCount}
          />
        </div>
      )}
    </OperationsSection>
  )
}
