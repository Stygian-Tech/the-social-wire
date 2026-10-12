import { expect, it } from "bun:test";
import { aggregateAnalytics } from "@/lib/analytics/aggregateAnalytics";
import type { AnalyticsSummary } from "@/lib/analytics/creatorAnalyticsClient";

function summary(impressions: number, clicks: number, likes: number | null): AnalyticsSummary {
  return { items: [], series: [], totals: { engagement: { likes, replies: null, reposts: null, quotes: null }, tracking: { impressions, views: 0, outboundClicks: clicks, ctr: impressions ? clicks / impressions * 100 : null } }, coverage: { snapshotStart: null, inventoryComplete: true, trackingScope: "social-wire", platformImpressions: null } };
}
it("weights combined CTR by impressions and retains unknown engagement", () => {
  const aggregate = aggregateAnalytics([summary(10, 5, null), summary(90, 9, 4)]);
  expect(aggregate.totals.tracking.ctr).toBeCloseTo(14);
  expect(aggregate.totals.engagement.likes).toBe(4);
  expect(aggregate.totals.engagement.replies).toBeNull();
  expect(aggregateAnalytics([]).totals.tracking.ctr).toBeNull();
  expect(aggregateAnalytics([summary(0, 0, null)]).totals.engagement.likes).toBeNull();
});
it("sums observed daily series without converting missing metric observations to zero", () => {
  const a = summary(1, 0, null); const b = summary(1, 0, 2);
  a.series = [{ day: "2026-10-01", likes: null, replies: null, reposts: null, quotes: null, impressions: 1, views: 1, outboundClicks: 0 }];
  b.series = [{ day: "2026-10-01", likes: 2, replies: null, reposts: null, quotes: null, impressions: 1, views: 2, outboundClicks: 0 }, { day: "2026-10-02", likes: null, replies: null, reposts: null, quotes: null, impressions: null, views: null, outboundClicks: null }];
  expect(aggregateAnalytics([a, b]).series[0]).toMatchObject({ likes: 2, views: 3, replies: null });
  expect(aggregateAnalytics([a, b]).series[1].views).toBeNull();
});
