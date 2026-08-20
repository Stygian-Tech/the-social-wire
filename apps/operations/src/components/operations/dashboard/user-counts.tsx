import { UserRound, Users } from "lucide-react"
import { boundedNonNegativeInteger, elapsedSeconds } from "@/lib/observability-values"
import type { Overview } from "@/lib/operations-types"

const formatCount = (value?: number) => boundedNonNegativeInteger(value)?.toLocaleString() ?? "—"

export function UserCounts({ overview, referenceTime = overview.refreshedAt }: { overview: Overview; referenceTime?: string }) {
  const viewers = overview.viewers
  if (!viewers)
    return (
      <section className="ops-panel p-3 text-[10px] text-muted-foreground" aria-label="Users">
        User counts are unavailable. The Operations database reported no AppView viewer projections.
      </section>
    )
  const observationAge = elapsedSeconds(viewers.observedAt, referenceTime)
  const items = [
    {
      label: "Known Users",
      value: formatCount(viewers.knownViewers),
      note: "Viewers the AppView holds sidebar or feed projections for",
      icon: Users,
    },
    {
      label: "Active Users (7d)",
      value: formatCount(viewers.activeViewers7d),
      note: "Projection refreshed in the last 7 days",
      icon: UserRound,
    },
    {
      label: "Active Users (30d)",
      value: formatCount(viewers.activeViewers30d),
      note: "Projection refreshed in the last 30 days",
      icon: UserRound,
    },
  ]
  return (
    <section className="ops-panel" aria-label="Users">
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
      <p className="border-t border-border/45 bg-muted/15 px-3 py-2.5 text-[9px] text-muted-foreground">
        Accounts live on their PDS, so these are viewers with rebuildable AppView projections, not a
        registration count. Activity reflects projection writes rather than sign-ins.
        {observationAge === null ? "" : ` Observed ${observationAge.toFixed(0)}s ago.`}
      </p>
    </section>
  )
}
