import { metricLabel, type AnalyticsPoint } from "@/lib/analytics/creatorAnalyticsClient";

export function AnalyticsTrend({ points, metric, title, description }: { points: AnalyticsPoint[]; metric: "likes" | "views"; title: string; description: string }) {
  const values = points.filter(point => point[metric] != null && Number.isFinite(point[metric]));
  const max = Math.max(1, ...values.map(point => point[metric]!));
  const firstDay = Date.parse(points[0]?.day ?? "");
  const lastDay = Date.parse(points.at(-1)?.day ?? "");
  const x = (index: number) => lastDay > firstDay ? 24 + (Date.parse(points[index].day) - firstDay) * 552 / (lastDay - firstDay) : 300;
  const y = (value: number) => 146 - value / max * 120;
  return <section className="min-w-0 rounded-2xl border bg-card p-4">
    <h2 className="font-semibold">{title}</h2><p className="mt-1 text-xs text-muted-foreground">{description}</p>
    {values.length ? <>
      <svg className="mt-3 h-44 w-full" viewBox="0 0 600 176" role="img" aria-label={`${title}. ${values.length} recorded days. Latest value ${metricLabel(values.at(-1)?.[metric])}.`}>
        <line x1="24" x2="576" y1="146" y2="146" stroke="currentColor" className="text-border" />
        <text x="24" y="18" fill="currentColor" className="text-muted-foreground" fontSize="11">{metricLabel(max)}</text>
        {points.map((point, index) => {
          const value = point[metric];
          if (value == null || !Number.isFinite(value)) return null;
          const previous = points[index - 1]?.[metric];
          const adjacentDay = index > 0 && Date.parse(point.day) - Date.parse(points[index - 1].day) === 86_400_000;
          return <g key={point.day}>{adjacentDay && previous != null && Number.isFinite(previous) ? <line x1={x(index - 1)} y1={y(previous)} x2={x(index)} y2={y(value)} stroke="currentColor" strokeWidth="2" className="text-primary" /> : null}<circle cx={x(index)} cy={y(value)} r="3" fill="currentColor" className="text-primary"><title>{point.day}: {metricLabel(value)}</title></circle></g>;
        })}
        <text x="24" y="170" fill="currentColor" fontSize="11">{points[0]?.day}</text><text x="576" y="170" textAnchor="end" fill="currentColor" fontSize="11">{points.at(-1)?.day}</text>
      </svg>
      <details className="text-xs"><summary className="cursor-pointer text-muted-foreground">View Chart Data</summary><table className="mt-2 w-full text-left"><thead><tr><th>Date</th><th>{metric === "likes" ? "Likes" : "Views"}</th></tr></thead><tbody>{points.map(point => <tr key={point.day}><td>{point.day}</td><td>{metricLabel(point[metric])}</td></tr>)}</tbody></table></details>
    </> : <p className="py-12 text-center text-sm text-muted-foreground">No Recorded History Yet</p>}
  </section>;
}
