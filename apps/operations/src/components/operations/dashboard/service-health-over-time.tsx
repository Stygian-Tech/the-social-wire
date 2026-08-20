import { HeartPulse } from "lucide-react"

import {
  GroupedEvidenceChart,
  type GroupedChartDatum,
} from "@/components/operations/dashboard/grouped-evidence-chart"
import { OperationsSection } from "@/components/operations/operations-section"
import { OperationsEmptyState } from "@/components/operations/operations-empty-state"
import { Badge } from "@/components/ui/badge"
import type { MetricRollup } from "@/lib/operations-types"
import {
  latestServiceHealthPercentages,
  serviceHealthRollingTrends,
} from "@/lib/service-health-trends"

const percentage = (value: number) => `${value.toLocaleString(undefined, { maximumFractionDigits: 1 })}%`

export function ServiceHealthOverTime({ metricRollups }: { metricRollups: MetricRollup[] }) {
  const trends = serviceHealthRollingTrends(metricRollups)
  const latest = latestServiceHealthPercentages(trends)
  const latestValues = latest
    ? [latest.liveness, latest.readiness, latest.freshness, latest.completeness]
        .filter((value): value is number => value !== null)
    : []
  const minimum = latestValues.length > 0 ? Math.min(...latestValues) : null

  return (
    <OperationsSection
      title={<span className="flex items-center gap-2"><HeartPulse className="size-3.5" /> Service Health Over Time</span>}
      description="Five-minute rolling healthy-sample percentage. Liveness and readiness cover all required services; projection freshness and completeness cover appview-worker. Hard alerts and durability remain separate evidence."
      action={<Badge tone={minimum === null ? "neutral" : "info"}>{minimum === null ? "No samples" : `${percentage(minimum)} minimum`}</Badge>}
    >
      {trends.length === 0 ? (
        <OperationsEmptyState>No service-health samples are available in the retained metrics window.</OperationsEmptyState>
      ) : (
        <div className="p-3">
          <GroupedEvidenceChart
            title="Five-Minute Rolling Health"
            description="Healthy samples divided by all reported health-state samples; gaps remain visible when a required service has no current bucket"
            unit="healthy samples (%)"
            source="socialwire.service.health.samples_total"
            data={trends as unknown as GroupedChartDatum[]}
            series={[
              { key: "liveness", label: "Required Services Liveness", color: "var(--success)" },
              { key: "readiness", label: "Required Services Readiness", color: "var(--primary)" },
              { key: "freshness", label: "Worker Freshness", color: "var(--info)" },
              { key: "completeness", label: "Worker Completeness", color: "var(--warning)", dashed: true },
            ]}
            valueFormatter={percentage}
          />
        </div>
      )}
    </OperationsSection>
  )
}
