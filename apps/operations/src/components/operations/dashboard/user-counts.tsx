import { UserRound, Users } from "lucide-react"
import { GroupedEvidenceChart } from "@/components/operations/dashboard/grouped-evidence-chart"
import { boundedNonNegativeInteger, elapsedSeconds } from "@/lib/observability-values"
import type { Overview } from "@/lib/operations-types"
import { formatUserCountDate, userCountTrends } from "@/lib/user-count-trends"

const formatCount = (value?: number) => boundedNonNegativeInteger(value)?.toLocaleString() ?? "—"

export function UserCounts({ overview, referenceTime = overview.refreshedAt }: { overview: Overview; referenceTime?: string }) {
  const viewers = overview.viewers
  const trends = userCountTrends(overview.viewerHistory ?? [], referenceTime)
  const observedDays = trends.filter((day) => day.known !== null || day.mau !== null || day.wau !== null).length
  const observationAge = elapsedSeconds(viewers?.observedAt, referenceTime)
  const items = [
    {
      label: "Known Users",
      value: formatCount(viewers?.knownViewers),
      note: "Viewers the AppView holds sidebar or feed projections for",
      icon: Users,
    },
    {
      label: "MAUs",
      value: formatCount(viewers?.activeViewers30d),
      note: "Projection refreshed in the last 30 days",
      icon: UserRound,
    },
    {
      label: "WAUs",
      value: formatCount(viewers?.activeViewers7d),
      note: "Projection refreshed in the last 7 days",
      icon: UserRound,
    },
  ]
  return (
    <section className="ops-panel" aria-label="Users">
      {!viewers ? (
        <p className="p-3 text-[10px] text-muted-foreground">
          User counts are unavailable. The Operations database reported no AppView viewer projections.
        </p>
      ) : null}
      <div className="ops-metric-grid sm:grid-cols-3">
        {items.map((item) => (
          <div key={item.label} className="ops-stat-cell">
            <div className="flex items-center gap-2 text-[11px]">
              <item.icon className="size-3.5" />
              {item.label}
            </div>
            <p className="mt-1 text-sm font-medium">{item.value}</p>
            <p className="mt-1 text-[10px] text-muted-foreground">{item.note}</p>
          </div>
        ))}
      </div>
      {observedDays > 0 ? (
        <div className="border-t border-border/45 p-3">
          <GroupedEvidenceChart
            title="Users Over Time"
            description="Last 90 days · Latest observation per UTC day, refreshed hourly · Missing days remain gaps"
            unit="users"
            source="Daily AppView viewer snapshots"
            data={trends}
            series={[
              { key: "known", label: "Known Users", color: "var(--chart-1)" },
              { key: "mau", label: "MAUs", color: "var(--chart-2)" },
              { key: "wau", label: "WAUs", color: "var(--chart-3)" },
            ]}
            timeFormatter={formatUserCountDate}
            valueFormatter={(value) => value.toLocaleString()}
            bucketLabel="UTC days"
            showIsolatedDots
            sampleCount={observedDays}
          />
        </div>
      ) : (
        <p className="border-t border-border/45 p-3 text-[10px] text-muted-foreground">
          No daily user history is available yet. The 90-day graph will fill as daily snapshots are collected.
        </p>
      )}
      <p className="border-t border-border/45 bg-muted/15 px-3 py-2.5 text-[9px] text-muted-foreground">
        Accounts live on their PDS, so these are viewers with rebuildable AppView projections, not a
        registration count. Activity reflects projection writes rather than sign-ins.
        {observationAge === null ? "" : ` Observed ${observationAge.toFixed(0)}s ago.`}
      </p>
    </section>
  )
}
