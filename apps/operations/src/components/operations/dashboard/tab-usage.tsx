import { OperationsSection } from "@/components/operations/operations-section"
import type { TabUsageSummary } from "@/lib/operations-types"

const labels: Record<string, string> = { home: "Home", wire: "The Wire", circle: "Your Circle", "live-post": "Live Post", "brand-accounts": "Brand Accounts", "content-calendar": "Content Calendar" }
const label = (tab: string) => labels[tab] ?? tab[0].toUpperCase() + tab.slice(1)
const duration = (ms: number) => `${(ms / 60_000).toLocaleString(undefined, { maximumFractionDigits: 1 })} min`

export function TabUsage({ usage }: { usage?: TabUsageSummary }) {
  const maximum = Math.max(1, ...usage?.tabs.map(row => row.opens) ?? [])
  return <OperationsSection title={usage?.sourceEnvironment === "local" ? "Local Web Activity" : "App and Tab Usage"} description="Authenticated web activity only. DAU: today UTC; WAU: last 7 UTC dates; MAU: last 30 UTC dates. Users are deduplicated across tabs; identities are never returned.">
    {!usage ? <p className="p-3 text-xs text-muted-foreground">Tab usage telemetry is unavailable.</p> : <>
      <dl className="ops-metric-grid sm:grid-cols-3">{[["DAUs", usage.dau], ["WAUs", usage.wau], ["MAUs", usage.mau]].map(([name, value]) => <div className="ops-stat-cell" key={name}><dt className="text-xs">{name}</dt><dd className="mt-1 text-lg font-semibold">{Number(value).toLocaleString()}</dd></div>)}</dl>
      {!usage.tabs.length ? <p className="p-3 text-xs text-muted-foreground">No tab usage has been observed yet. Historical usage is unavailable.</p> : <div className="overflow-x-auto"><table className="w-full text-left text-[11px]"><caption className="px-3 py-2 text-left text-muted-foreground">Visits and visible dwell in the retained 30-day window. Visits count tab opens, not unique users. Background time is excluded.</caption><thead><tr>{["Tab", "Visits", "DAUs", "WAUs", "MAUs", "Visible Time", "Average per Visit"].map(name => <th className="whitespace-nowrap px-3 py-2" key={name}>{name}</th>)}</tr></thead><tbody>{usage.tabs.map(row => <tr className="border-t border-border/45" key={row.tab}><th scope="row" className="min-w-32 px-3 py-2 font-medium">{label(row.tab)}<span aria-hidden="true" className="mt-1 block h-1 rounded bg-primary/20"><span className="block h-full rounded bg-primary" style={{ width: `${row.opens / maximum * 100}%` }} /></span></th>{[row.opens, row.dau, row.wau, row.mau].map((value, index) => <td className="px-3 py-2 tabular-nums" key={index}>{value.toLocaleString()}</td>)}<td className="whitespace-nowrap px-3 py-2">{duration(row.dwellMs)}</td><td className="whitespace-nowrap px-3 py-2">{row.opens ? duration(row.dwellMs / row.opens) : "—"}</td></tr>)}</tbody></table></div>}
      <p className="border-t border-border/45 px-3 py-2 text-[10px] text-muted-foreground">Server storage contains keyed pseudonyms and known tab labels, not DIDs, handles, URLs, or message content. Pseudonym rows become eligible for bounded hourly deletion after 30 UTC dates. Telemetry starts with this release, respects Do Not Track, and excludes signed-out activity.</p>
    </>}
  </OperationsSection>
}
