import type { OAuthSession } from "@atproto/oauth-client-browser";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";

export type EngagementMetrics = { likes: number | null; replies: number | null; reposts: number | null; quotes: number | null };
export type TrackingMetrics = { impressions: number | null; views: number | null; outboundClicks: number | null; ctr: number | null };
export type AnalyticsItem = { uri: string; kind: "post" | "article"; title: string; url: string; publishedAt: string; engagement: EngagementMetrics | null; tracking: TrackingMetrics; refreshedAt: string | null };
export type AnalyticsPoint = EngagementMetrics & Omit<TrackingMetrics, "ctr"> & { day: string };
export type AnalyticsSummary = {
  items: AnalyticsItem[];
  totals: { engagement: EngagementMetrics | null; tracking: TrackingMetrics };
  series: AnalyticsPoint[];
  coverage: { trackingStart?: string | null; snapshotStart: string | null; inventoryComplete: boolean; trackingScope: "social-wire"; platformImpressions: null; sampledAt?: string | null; engagementKnownItems?: number; totalItems?: number; excludesSelf?: boolean; trackingRetentionDays?: number; snapshotSemantics?: string };
  cursor?: string;
};

export async function getCreatorAnalytics(session: OAuthSession, options: { days: number; cursor?: string; signal?: AbortSignal; refresh?: boolean }): Promise<AnalyticsSummary> {
  const query = new URLSearchParams({ days: String(options.days), limit: "50" });
  if (options.cursor) query.set("cursor", options.cursor);
  const response = await gatewayFetch(session, `/v1/analytics/${options.refresh ? "refresh" : "summary"}?${query}`, { method: options.refresh ? "POST" : "GET", signal: options.signal });
  if (!response.ok) {
    throw new Error(response.status === 401 || response.status === 403 ? "Log in again to allow Analytics to access your account." : `Analytics could not be loaded (${response.status}). Please try again.`);
  }
  return await response.json() as AnalyticsSummary;
}

export function uniqueAnalyticsItems(pages: AnalyticsSummary[]): AnalyticsItem[] {
  return [...new Map(pages.flatMap(page => page.items).map(item => [item.uri, item])).values()];
}

export function metricLabel(value: number | null | undefined, percent = false): string {
  if (value == null || !Number.isFinite(value)) return "—";
  return percent ? `${value.toFixed(1)}%` : value.toLocaleString();
}

/** Aggregate days are UTC calendar dates, not instants in the viewer's timezone. */
export function analyticsCalendarDay(day: string, locale?: string): string {
  return new Date(`${day}T00:00:00Z`).toLocaleDateString(locale, { timeZone: "UTC" });
}

export function safeAnalyticsUrl(value: string): string | undefined {
  try { const url = new URL(value); return url.protocol === "https:" && !url.username && !url.password ? url.href : undefined; } catch { return undefined; }
}
