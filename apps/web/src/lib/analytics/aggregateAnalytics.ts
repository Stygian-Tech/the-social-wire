import type { AnalyticsSummary, AnalyticsPoint } from "./creatorAnalyticsClient";

/** Sum available observations; null remains unknown when no account observed a metric. */
function observedSum(values: (number | null | undefined)[]): number | null {
  const known = values.filter((value): value is number => value != null && Number.isFinite(value));
  return known.length ? known.reduce((sum, value) => sum + value, 0) : null;
}

export function aggregateAnalytics(summaries: AnalyticsSummary[]) {
  const engagementKeys = ["likes", "replies", "reposts", "quotes"] as const;
  const trafficKeys = ["impressions", "views", "outboundClicks"] as const;
  const engagement = Object.fromEntries(engagementKeys.map(key => [key, observedSum(summaries.map(summary => summary.totals.engagement?.[key]))])) as NonNullable<AnalyticsSummary["totals"]["engagement"]>;
  const tracking = Object.fromEntries(trafficKeys.map(key => [key, observedSum(summaries.map(summary => summary.totals.tracking[key]))])) as Omit<AnalyticsSummary["totals"]["tracking"], "ctr">;
  const ctr = tracking.impressions && tracking.outboundClicks != null ? tracking.outboundClicks / tracking.impressions * 100 : null;
  const dates = [...new Set(summaries.flatMap(summary => summary.series.map(point => point.day)))].sort();
  const series: AnalyticsPoint[] = dates.map(day => {
    const points = summaries.flatMap(summary => summary.series.filter(point => point.day === day));
    return { day, ...Object.fromEntries([...engagementKeys, ...trafficKeys].map(key => [key, observedSum(points.map(point => point[key]))])) } as AnalyticsPoint;
  });
  return { totals: { engagement, tracking: { ...tracking, ctr } }, series };
}
