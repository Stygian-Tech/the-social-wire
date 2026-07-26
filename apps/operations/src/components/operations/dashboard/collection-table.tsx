import { EvidenceLineChart } from "@/components/operations/dashboard/evidence-line-chart"
import { OperationsSection } from "@/components/operations/operations-section"
import { Badge } from "@/components/ui/badge"
import {
  collectionMetricRows,
  currentMetricValue,
  metricSampleCount,
  MONITORED_COLLECTIONS,
} from "@/lib/collection-metrics"
import type { MetricPoint } from "@/lib/collection-metrics"
import type { EvidenceEnvelope, MetricRollup } from "@/lib/operations-types"

const formatIndexedRate = (value: number) =>
  `${value < 1 ? value.toLocaleString(undefined, { maximumFractionDigits: 2 }) : Math.round(value).toLocaleString()} indexed events/sec`
const formatFailedRate = (value: number) =>
  `${value < 1 ? value.toLocaleString(undefined, { maximumFractionDigits: 2 }) : Math.round(value).toLocaleString()} failed events/sec`

function observedValue(points: MetricPoint[], format = formatIndexedRate) {
  const value = currentMetricValue(points)
  return value === null ? "— Missing" : format(value)
}

export function CollectionTable({
  metricRollups,
  refreshedAt,
  referenceTime = refreshedAt,
  evidence,
}: {
  metricRollups: MetricRollup[]
  refreshedAt: string
  referenceTime?: string
  evidence?: EvidenceEnvelope
}) {
  const rows = collectionMetricRows(metricRollups, refreshedAt, MONITORED_COLLECTIONS)

  return (
    <OperationsSection
      title="Indexed Events/sec. by Collection"
      description="15 closed one-minute buckets. Missing buckets remain gaps; zero is shown only when it was observed."
    >
      {rows.length === 0 ? (
        <p className="p-6 text-center text-xs text-muted-foreground">
          No measured collection rollups are available for this window.
        </p>
      ) : (
        <div className="grid gap-3 p-3 xl:grid-cols-2">
          {rows.map((row) => (
            <article key={row.collection} className="min-w-0 rounded-md border bg-muted/10 p-3">
              <header className="mb-3 flex flex-wrap items-center justify-between gap-2">
                <h3 className="break-all font-mono text-xs font-semibold">{row.collection}</h3>
                <Badge tone="info">Indexed, Not Received</Badge>
              </header>
              <EvidenceLineChart
                points={row.allOperationsRate}
                title="Indexed Events/sec."
                unit="indexed events per second"
                source="AppView Worker indexed-mutation rollups"
                format={formatIndexedRate}
                refreshedAt={refreshedAt}
                referenceTime={referenceTime}
                evidence={evidence}
                sampleCount={metricSampleCount(
                  metricRollups,
                  row.collection,
                  "socialwire.ingestion.events_total",
                )}
              />
              <dl className="mt-3 grid grid-cols-2 gap-px overflow-hidden rounded-md border bg-border sm:grid-cols-4">
                {[
                  ["Create", observedValue(row.createRate)],
                  ["Update", observedValue(row.updateRate)],
                  ["Delete", observedValue(row.deleteRate)],
                  ["Failed", observedValue(row.failedRate, formatFailedRate)],
                ].map(([label, value]) => (
                  <div key={label} className="bg-background p-2.5">
                    <dt className="text-[9px] text-muted-foreground">{label} · latest closed bucket</dt>
                    <dd className="mt-1 font-mono text-xs">{value}</dd>
                  </div>
                ))}
              </dl>
            </article>
          ))}
        </div>
      )}
    </OperationsSection>
  )
}
