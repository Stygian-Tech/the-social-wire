import { Gauge } from "lucide-react"

import { OperationsSection } from "@/components/operations/operations-section"
import { Badge } from "@/components/ui/badge"
import { subscribedFeedPerformanceRows } from "@/lib/subscribed-feed-metrics"
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
  const sampleCount = rows.reduce((total, row) => total + row.requestSamples, 0)

  return (
    <OperationsSection
      title={<span className="flex items-center gap-2"><Gauge className="size-3.5" /> Subscribed Feed Performance</span>}
      description="Observed AppView aggregate-feed rollups from the closed 15-minute window. Values are averages and maxima, not percentiles."
      action={<Badge tone={sampleCount > 0 ? "success" : "neutral"}>n={sampleCount.toLocaleString()}</Badge>}
    >
      {rows.length === 0 ? (
        <p className="p-6 text-center text-xs text-muted-foreground">
          No Subscribed-feed performance samples are available in the retained window.
        </p>
      ) : (
        <div className="grid gap-3 p-3 xl:grid-cols-2">
          {rows.map((row) => (
            <article key={row.pageKind} className="min-w-0 rounded-md border bg-muted/10 p-3">
              <header className="mb-3 flex items-center justify-between gap-2">
                <h3 className="text-xs font-semibold">
                  {row.pageKind === "first_page" ? "First Page" : "Pagination"}
                </h3>
                <Badge tone="neutral">{row.requestSamples.toLocaleString()} requests</Badge>
              </header>
              <dl className="grid grid-cols-2 gap-3 sm:grid-cols-3">
                <Metric label="Average Query" value={`${formatNumber(row.averageQueryMilliseconds)} ms`} />
                <Metric label="Maximum Query" value={`${formatNumber(row.maximumQueryMilliseconds)} ms`} />
                <Metric label="Scan Yield" value={row.scanYieldRatio === null ? "—" : `${formatNumber(row.scanYieldRatio * 100)}%`} />
                <Metric label="Average Scanned" value={formatNumber(row.averageRowsScanned)} />
                <Metric label="Average Returned" value={formatNumber(row.averageRowsReturned)} />
                <Metric label="Average Payload" value={formatBytes(row.averagePayloadBytes)} />
              </dl>
              <p className="mt-3 text-[9px] text-muted-foreground">
                {formatNumber(row.duplicatesSuppressed, 0)} canonical duplicates suppressed in this window.
              </p>
            </article>
          ))}
        </div>
      )}
    </OperationsSection>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-[9px] text-muted-foreground">{label}</dt>
      <dd className="mt-1 font-mono text-sm font-medium">{value}</dd>
    </div>
  )
}
