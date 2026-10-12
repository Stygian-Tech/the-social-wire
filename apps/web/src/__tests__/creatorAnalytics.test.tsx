import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Gateway from "@/lib/socialWireGatewayClient";
import { analyticsCalendarDay, getCreatorAnalytics, metricLabel, safeAnalyticsUrl, uniqueAnalyticsItems, type AnalyticsSummary } from "@/lib/analytics/creatorAnalyticsClient";
import { AnalyticsTrend } from "@/components/Analytics/AnalyticsTrend";

export function analyticsFixture(): AnalyticsSummary {
  return { items: [], totals: { engagement: null, tracking: { impressions: 0, views: 0, outboundClicks: 0, ctr: null } }, series: [], coverage: { snapshotStart: null, inventoryComplete: true, trackingScope: "social-wire", platformImpressions: null } };
}
afterEach(cleanup);
describe("creator analytics", () => {
  it("uses authenticated gateway routes, encoded cursors, cancellation and bodyless refresh", async () => {
    const fetch = spyOn(Gateway, "gatewayFetch").mockImplementation(async () => Response.json(analyticsFixture()));
    try {
      const session = {} as OAuthSession; const signal = new AbortController().signal;
      await getCreatorAnalytics(session, { days: 7, cursor: "at://did:plc:a/a/b", signal });
      expect(fetch.mock.calls[0]![0]).toBe(session);
      expect(fetch.mock.calls[0]![1]).toBe("/v1/analytics/summary?days=7&limit=50&cursor=at%3A%2F%2Fdid%3Aplc%3Aa%2Fa%2Fb");
      expect(fetch.mock.calls[0]![2]).toEqual({ method: "GET", signal });
      await getCreatorAnalytics(session, { days: 90, refresh: true });
      expect(fetch.mock.calls[1]![1]).toBe("/v1/analytics/refresh?days=90&limit=50");
      expect(fetch.mock.calls[1]![2]?.body).toBeUndefined();
      fetch.mockResolvedValue(new Response("secret backend text", { status: 401 }));
      await expect(getCreatorAnalytics(session, { days: 30 })).rejects.toThrow("Log in again");
    } finally { fetch.mockRestore(); }
  });
  it("keeps unavailable metrics distinct from real zeros and percentages", () => {
    expect(metricLabel(null)).toBe("—"); expect(metricLabel(NaN)).toBe("—"); expect(metricLabel(0)).toBe("0"); expect(metricLabel(12.5, true)).toBe("12.5%");
  });
  it("formats UTC aggregate days without shifting them into the previous local day", () => {
    const format = spyOn(Date.prototype, "toLocaleDateString");
    try {
      expect(analyticsCalendarDay("2026-10-11", "en-US")).toBe("10/11/2026");
      expect(format).toHaveBeenCalledWith("en-US", { timeZone: "UTC" });
    } finally { format.mockRestore(); }
  });
  it("deduplicates canonical content without inventing values", () => {
    const item = { uri: "at://did:plc:a/app.bsky.feed.post/one", kind: "post" as const, title: "One", url: "", publishedAt: "", engagement: null, tracking: { impressions: 0, views: 0, outboundClicks: 0, ctr: null }, refreshedAt: null };
    expect(uniqueAnalyticsItems([{ ...analyticsFixture(), items: [item] }, { ...analyticsFixture(), items: [{ ...item, title: "Updated" }] }])).toEqual([{ ...item, title: "Updated" }]);
    expect(safeAnalyticsUrl("javascript:alert(1)")).toBeUndefined(); expect(safeAnalyticsUrl("https://user:pass@example.com")).toBeUndefined(); expect(safeAnalyticsUrl("https://example.com/article")).toBe("https://example.com/article");
  });
  it("shows empty history and accessible recorded samples without synthetic days", () => {
    const view = render(<AnalyticsTrend points={[]} metric="likes" title="Like Snapshots" description="Current counts" />);
    expect(screen.getByText("No Recorded History Yet")).toBeDefined();
    view.rerender(<AnalyticsTrend points={[{ day: "2026-10-11", likes: 4, replies: null, reposts: null, quotes: null, views: 0, impressions: 0, outboundClicks: 0 }]} metric="likes" title="Like Snapshots" description="Current counts" />);
    expect(screen.getByRole("img").getAttribute("aria-label")).toContain("1 recorded days. Latest value 4");
    expect(screen.getAllByRole("row")).toHaveLength(2);
  });
  it("does not connect samples across missing days or unavailable counts", () => {
    const base = { replies: null, reposts: null, quotes: null, views: 0, impressions: 0, outboundClicks: 0 };
    const view = render(<AnalyticsTrend points={[{ ...base, day: "2026-10-01", likes: 4 }, { ...base, day: "2026-10-03", likes: 8 }, { ...base, day: "2026-10-04", likes: null }, { ...base, day: "2026-10-05", likes: 12 }]} metric="likes" title="Like Snapshots" description="Current counts" />);
    expect(view.container.querySelectorAll("circle")).toHaveLength(3);
    expect(view.container.querySelectorAll("line")).toHaveLength(1);
    expect(screen.getAllByRole("row")).toHaveLength(5);
  });
});
