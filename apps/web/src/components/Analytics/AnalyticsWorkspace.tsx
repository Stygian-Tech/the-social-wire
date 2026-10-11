"use client";

import { useState } from "react";
import Link from "next/link";
import { ChevronDown, RefreshCw } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { useCreatorAnalytics } from "@/hooks/useCreatorAnalytics";
import { analyticsCalendarDay, metricLabel, safeAnalyticsUrl } from "@/lib/analytics/creatorAnalyticsClient";
import { isSocialPostUri, socialPostPageHref } from "@/lib/socialPostNavigation";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { SocialPermissionRecovery } from "@/components/Social/SocialPermissionRecovery";
import { Button } from "@/components/ui/button";
import { AnalyticsTrend } from "./AnalyticsTrend";

export function AnalyticsWorkspace() {
  const { session } = useAuth();
  return session ? <AnalyticsViewer key={session.did} /> : <p className="p-6">Log In to View Analytics.</p>;
}

function AnalyticsViewer() {
  const [days, setDays] = useState(30);
  const analytics = useCreatorAnalytics(days);
  const { summary, items, query, refresh } = analytics;
  const failure = query.error ?? refresh.error;
  const error = failure instanceof Error ? failure.message : failure ? "Analytics could not be loaded. Please try again." : undefined;
  const dates = items.flatMap(item => item.refreshedAt ? [item.refreshedAt] : []).sort();
  const fresh = summary?.coverage.sampledAt ?? dates.at(-1);
  return <div className="flex min-h-0 min-w-0 flex-1 flex-col">
    <FeedHeader title="Analytics" subtitle="Your Content and Engagement">
      <div className="relative"><select aria-label="Analytics Time Range" value={days} onChange={event => setDays(Number(event.target.value))} className="h-9 appearance-none rounded-lg border bg-background py-1 pl-3 pr-9 text-sm"><option value={7}>Last 7 Days</option><option value={30}>Last 30 Days</option><option value={90}>Last 90 Days</option></select><ChevronDown aria-hidden="true" className="pointer-events-none absolute right-3 top-3 size-3" /></div>
      <Button size="sm" variant="outline" disabled={refresh.isPending || query.isFetching} onClick={() => { void analytics.collect().catch(() => {}); }}><RefreshCw className={`size-4 ${refresh.isPending ? "animate-spin" : ""}`} />{refresh.isPending ? "Refreshing…" : "Refresh"}</Button>
    </FeedHeader>
    <div className="min-h-0 flex-1 overflow-y-auto p-3 sm:p-5">
      <div className="mx-auto max-w-6xl space-y-6">
        {error ? <div role="alert" className="rounded-xl border border-destructive/40 p-4 text-sm"><p>{error}</p>{/log in again/i.test(error) ? <SocialPermissionRecovery /> : <Button className="mt-2" size="sm" variant="outline" onClick={() => { void query.refetch(); }}>Retry</Button>}</div> : null}
        {query.isPending ? <p role="status" className="py-12 text-center text-muted-foreground">Loading Analytics…</p> : null}
        {summary ? <>
          <section aria-label="Analytics Coverage" className="space-y-1 rounded-xl border p-4 text-xs text-muted-foreground">
            <p>Bluesky: Current Cumulative Engagement · Social Wire: Recorded Events in the Last {days} Days</p>
            <p>{summary.coverage.inventoryComplete ? "Content inventory is complete." : "Coverage is limited to the latest indexed content; totals may exclude older content."} Platform impressions are unavailable.</p>
            <p>{summary.coverage.snapshotStart ? `Snapshot history began ${analyticsCalendarDay(summary.coverage.snapshotStart)}.` : "Snapshot history starts with your first refresh."} {fresh ? `Last content refresh: ${new Date(fresh).toLocaleString()}.` : "No content refresh recorded yet."}</p>
            <p>{summary.coverage.engagementKnownItems != null ? `${summary.coverage.engagementKnownItems} of ${summary.coverage.totalItems ?? items.length} indexed items have platform engagement; totals include known counts only. ` : ""}Social Wire tracking covers signed-in activity inside this app; external site traffic and iframe clicks are unavailable.{summary.coverage.excludesSelf ? " Your own activity is excluded." : ""} Unavailable metrics are shown as —.</p>
            <p>{summary.coverage.trackingStart ? `Tracking history began ${analyticsCalendarDay(summary.coverage.trackingStart)}.` : "No Social Wire traffic recorded yet."} Impressions require a card to be visible for one second; views count opened posts and articles. Outbound clicks require a recorded impression and are deduplicated per viewer, content, and UTC day.</p>
          </section>
          <section><h2 className="mb-2 font-semibold">Bluesky Engagement</h2><p className="mb-3 text-xs text-muted-foreground">Current Counts Across Indexed Posts · These Are Not Gains During the Selected Period</p><Metrics values={[["Likes", summary.totals.engagement?.likes], ["Replies", summary.totals.engagement?.replies], ["Reposts", summary.totals.engagement?.reposts], ["Quotes", summary.totals.engagement?.quotes]]} /></section>
          <section><h2 className="mb-2 font-semibold">Social Wire Activity</h2><p className="mb-3 text-xs text-muted-foreground">Last {days} Days · Click-Through Rate Is Outbound Clicks Divided by Impressions</p><Metrics values={[["Impressions", summary.totals.tracking.impressions], ["Views", summary.totals.tracking.views], ["Outbound Clicks", summary.totals.tracking.outboundClicks], ["Click-Through Rate", summary.totals.tracking.ctr, true]]} /></section>
          <div className="grid gap-4 lg:grid-cols-2"><AnalyticsTrend points={summary.series} metric="likes" title="Bluesky Like Snapshots" description="Latest cumulative like count at each recorded daily refresh. Missing days are not reconstructed." /><AnalyticsTrend points={summary.series} metric="views" title="Social Wire Views" description="Views recorded each day inside Social Wire during the selected period." /></div>
          <section className="overflow-hidden rounded-2xl border bg-card"><h2 className="p-4 font-semibold">Content Performance</h2>
            {!items.length ? <p className="px-4 pb-8 text-sm text-muted-foreground">No Content Indexed Yet. Select Refresh to Collect Your Posts and Articles.</p> : <div className="overflow-x-auto"><table className="w-full text-left text-xs"><thead className="bg-muted/40"><tr>{["Content", "Likes", "Replies", "Reposts", "Quotes", "Views", "Impressions", "Clicks", "CTR"].map(label => <th key={label} scope="col" className="whitespace-nowrap px-3 py-3 font-medium">{label}</th>)}</tr></thead><tbody>{items.map(item => {
              const href = isSocialPostUri(item.uri) ? socialPostPageHref(item.uri) : safeAnalyticsUrl(item.url);
              return <tr key={item.uri} className="border-t"><td className="min-w-56 max-w-96 px-3 py-3"><p className="mb-1 text-[10px] text-muted-foreground">{item.kind === "post" ? "Post" : "Article"} · {item.publishedAt ? new Date(item.publishedAt).toLocaleDateString() : "Date Unavailable"}</p>{href ? <Link href={href} className="line-clamp-2 break-words hover:underline">{item.title || "Untitled Content"}</Link> : <span>{item.title || "Untitled Content"}</span>}</td>{[item.engagement?.likes, item.engagement?.replies, item.engagement?.reposts, item.engagement?.quotes, item.tracking.views, item.tracking.impressions, item.tracking.outboundClicks].map((value, index) => <td key={index} className="px-3 py-3 tabular-nums">{metricLabel(value)}</td>)}<td className="px-3 py-3 tabular-nums">{metricLabel(item.tracking.ctr, true)}</td></tr>;
            })}</tbody></table></div>}
            {query.hasNextPage ? <div className="p-3"><Button variant="outline" size="sm" disabled={query.isFetchingNextPage} onClick={() => { void query.fetchNextPage(); }}>{query.isFetchingNextPage ? "Loading…" : "Load More Content"}</Button></div> : null}
          </section>
        </> : null}
      </div>
    </div>
  </div>;
}

function Metrics({ values }: { values: [string, number | null | undefined, boolean?][] }) {
  return <dl className="grid grid-cols-2 gap-3 lg:grid-cols-4">{values.map(([label, value, percent]) => <div key={label} className="rounded-2xl border bg-card p-4"><dt className="text-xs text-muted-foreground">{label}</dt><dd className="mt-2 text-2xl font-semibold tabular-nums">{metricLabel(value, percent)}</dd></div>)}</dl>;
}
