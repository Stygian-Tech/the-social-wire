import {
  GroupedEvidenceChart,
  mergeGroupedSeries,
} from "@/components/operations/dashboard/grouped-evidence-chart"
import { OperationsSection } from "@/components/operations/operations-section"
import { OperationsEmptyState } from "@/components/operations/operations-empty-state"
import { Badge } from "@/components/ui/badge"
import {
  collectionMetricRows,
  currentMetricValue,
  metricSampleCount,
  MONITORED_COLLECTIONS,
} from "@/lib/collection-metrics"
import type { EvidenceEnvelope, MetricRollup } from "@/lib/operations-types"

const formatMilliseconds = (value: number) => `${Math.round(value).toLocaleString()} ms`
const formatSeconds = (value: number) => `${value.toLocaleString(undefined, { maximumFractionDigits: 2 })} s`

function sectionEvidenceStatus(evidence: EvidenceEnvelope | undefined, referenceTime: string) {
  if (!evidence) return { label: "Evidence Unavailable", tone: "neutral" as const }
  const generatedAt = new Date(evidence.generatedAt).getTime()
  const reference = new Date(referenceTime).getTime()
  const validUntil = new Date(evidence.validUntil).getTime()
  if (!Number.isFinite(generatedAt) || !Number.isFinite(reference) || reference < generatedAt)
    return { label: "Evidence Unavailable", tone: "neutral" as const }

  const ageSeconds = evidence.ageSeconds + (reference - generatedAt) / 1_000
  if (!Number.isFinite(ageSeconds) || ageSeconds < 0)
    return { label: "Evidence Unavailable", tone: "neutral" as const }

  const ageLabel = `${Math.round(ageSeconds)}s old`
  if (!Number.isFinite(validUntil) || validUntil < reference)
    return { label: `Expired · ${ageLabel}`, tone: "danger" as const }
  if (evidence.accuracy === "unavailable")
    return { label: `Unavailable · ${ageLabel}`, tone: "neutral" as const }
  if (evidence.accuracy !== "exact" || evidence.degradedReason || (evidence.coverage ?? 1) < 1)
    return { label: `Partial · ${ageLabel}`, tone: "warning" as const }
  return { label: `Current · ${ageLabel}`, tone: "success" as const }
}

export function CollectionHealth({
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
  const sectionStatus = sectionEvidenceStatus(evidence, referenceTime)

  return (
    <OperationsSection
      title="Collection Processing Evidence"
      description="Observed latency and event lag. No health claim is made without a server-provided threshold and sample floor."
      action={<Badge tone={sectionStatus.tone}>{sectionStatus.label}</Badge>}
    >
      {rows.length === 0 ? (
        <OperationsEmptyState>No processing evidence is available.</OperationsEmptyState>
      ) : (
        <div className="grid gap-3 p-3">
          {rows.map((row) => {
            const failures = currentMetricValue(row.failedRate)
            return (
              <article key={row.collection} className="ops-subpanel min-w-0">
                <header className="mb-3 flex flex-wrap items-center justify-between gap-2">
                  <h3 className="break-all font-mono text-xs font-semibold">{row.collection}</h3>
                  <Badge tone={failures === null ? "neutral" : failures > 0 ? "danger" : "success"}>
                    {failures === null ? "Latest Failure Evidence Missing" : failures > 0 ? "Failures Observed" : "No Failures in Latest Bucket"}
                  </Badge>
                </header>
                <div className="grid gap-3 xl:grid-cols-2">
                  <GroupedEvidenceChart
                    data={mergeGroupedSeries([
                      { key: "average", points: row.averageCommitMilliseconds },
                      { key: "maximum", points: row.maximumCommitMilliseconds },
                    ])}
                    series={[
                      { key: "average", label: "Average", color: "var(--primary)" },
                      { key: "maximum", label: "Maximum", color: "var(--warning)", dashed: true },
                    ]}
                    title="Database Commit Duration"
                    description="Average and maximum by closed one-minute bucket"
                    unit="milliseconds"
                    source="Charybdis database-write duration rollups"
                    valueFormatter={formatMilliseconds}
                    sampleCount={metricSampleCount(metricRollups, row.collection, "socialwire.ingestion.db_write_duration_seconds")}
                  />
                  <GroupedEvidenceChart
                    data={mergeGroupedSeries([
                      { key: "average", points: row.averageLagSeconds },
                      { key: "maximum", points: row.maximumLagSeconds },
                    ])}
                    series={[
                      { key: "average", label: "Average", color: "var(--info)" },
                      { key: "maximum", label: "Maximum", color: "var(--warning)", dashed: true },
                    ]}
                    title="Committed Event Lag"
                    description="Average and maximum by closed one-minute bucket"
                    unit="seconds"
                    source="Charybdis committed-event lag rollups"
                    valueFormatter={formatSeconds}
                    sampleCount={metricSampleCount(metricRollups, row.collection, "socialwire.ingestion.commit_lag_seconds")}
                  />
                </div>
              </article>
            )
          })}
        </div>
      )}
    </OperationsSection>
  )
}
