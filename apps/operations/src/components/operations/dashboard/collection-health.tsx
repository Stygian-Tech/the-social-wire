import { EvidenceLineChart } from "@/components/operations/dashboard/evidence-line-chart"
import { OperationsSection } from "@/components/operations/operations-section"
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
        <p className="p-6 text-center text-xs text-muted-foreground">No processing evidence is available.</p>
      ) : (
        <div className="grid gap-3 p-3">
          {rows.map((row) => {
            const failures = currentMetricValue(row.failedRate)
            return (
              <article key={row.collection} className="min-w-0 rounded-md border bg-muted/10 p-3">
                <header className="mb-3 flex flex-wrap items-center justify-between gap-2">
                  <h3 className="break-all font-mono text-xs font-semibold">{row.collection}</h3>
                  <Badge tone={failures === null ? "neutral" : failures > 0 ? "danger" : "success"}>
                    {failures === null ? "Latest Failure Evidence Missing" : failures > 0 ? "Failures Observed" : "No Failures in Latest Bucket"}
                  </Badge>
                </header>
                <div className="grid gap-3 xl:grid-cols-2">
                  <EvidenceLineChart
                    points={row.averageCommitMilliseconds}
                    title="Average Database Commit Duration"
                    unit="milliseconds"
                    source="AppView Worker database-write duration rollups"
                    format={formatMilliseconds}
                    refreshedAt={refreshedAt}
                    referenceTime={referenceTime}
                    evidence={evidence}
                    showFreshnessBadge={false}
                    sampleCount={metricSampleCount(metricRollups, row.collection, "socialwire.ingestion.db_write_duration_seconds")}
                  />
                  <EvidenceLineChart
                    points={row.averageLagSeconds}
                    title="Average Event Lag"
                    unit="seconds"
                    source="AppView Worker committed-event lag rollups"
                    format={formatSeconds}
                    refreshedAt={refreshedAt}
                    referenceTime={referenceTime}
                    evidence={evidence}
                    showFreshnessBadge={false}
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
