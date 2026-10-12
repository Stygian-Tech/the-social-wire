"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { RefreshCw } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { useCreatorAnalytics } from "@/hooks/useCreatorAnalytics";
import { metricLabel, safeAnalyticsUrl } from "@/lib/analytics/creatorAnalyticsClient";
import { isSocialPostUri, socialPostPageHref } from "@/lib/socialPostNavigation";
import { SocialPermissionRecovery } from "@/components/Social/SocialPermissionRecovery";
import { Button } from "@/components/ui/button";
import { AnalyticsTrend } from "./AnalyticsTrend";
import { AnalyticsAccountSelection } from "./AnalyticsAccountSelection";
import type { AnalyticsSummary } from "@/lib/analytics/creatorAnalyticsClient";

export function AnalyticsWorkspace() {
  const { session } = useAuth();
  return session ? <AnalyticsAccountSelection key={session.did} ownerDid={session.did} /> : <p className="p-6">Log In to View Analytics.</p>;
}

export function AnalyticsAccountDetails({ accountDid, days, onSummary }: { accountDid: string; days: number; onSummary: (did: string, summary: AnalyticsSummary | undefined) => void }) {
  const analytics = useCreatorAnalytics(days, accountDid);
  const [visibleCount, setVisibleCount] = useState(10);
  const { summary, items, query, refresh } = analytics;
  useEffect(() => { onSummary(accountDid, summary); return () => onSummary(accountDid, undefined); }, [accountDid, summary, onSummary]);
  const failure = query.error ?? refresh.error;
  const error = failure instanceof Error ? failure.message : failure ? "Analytics could not be loaded. Please try again." : undefined;
  const dates = items.flatMap(item => item.refreshedAt ? [item.refreshedAt] : []).sort();
  const fresh = summary?.coverage.sampledAt ?? dates.at(-1);
  return <div className="flex min-h-0 min-w-0 flex-1 flex-col">
    <div className="flex items-center justify-between gap-3 pb-3"><h2 className="font-semibold">Account Breakdown</h2><Button size="sm" variant="outline" disabled={refresh.isPending || query.isFetching} onClick={() => { void analytics.collect().catch(() => {}); }}><RefreshCw className={`size-4 ${refresh.isPending ? "animate-spin" : ""}`} />{refresh.isPending ? "Refreshing…" : "Refresh"}</Button></div>
    <div className="min-w-0">
      <div className="mx-auto max-w-6xl space-y-6">
        {error ? <div role="alert" className="rounded-xl border border-destructive/40 p-4 text-sm"><p>{error}</p>{/log in again/i.test(error) ? <SocialPermissionRecovery /> : <Button className="mt-2" size="sm" variant="outline" onClick={() => { void query.refetch(); }}>Retry</Button>}</div> : null}
        {query.isPending ? <p role="status" className="py-12 text-center text-muted-foreground">Loading Analytics…</p> : null}
        {summary ? <>
          <section aria-label="Analytics Coverage" className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted-foreground">
            <p>{fresh ? `Updated ${new Date(fresh).toLocaleString()}` : "Refresh to Collect Your Content"}</p>
            {!summary.coverage.inventoryComplete ? <p>Latest Content Only</p> : null}
          </section>
          <section><h2 className="mb-2 font-semibold">Bluesky Engagement</h2><p className="mb-3 text-xs text-muted-foreground">Current Counts Across Indexed Posts · These Are Not Gains During the Selected Period</p><Metrics values={[["Likes", summary.totals.engagement?.likes], ["Replies", summary.totals.engagement?.replies], ["Reposts", summary.totals.engagement?.reposts], ["Quotes", summary.totals.engagement?.quotes]]} /></section>
          <section><h2 className="mb-2 font-semibold">Social Wire Activity</h2><p className="mb-3 text-xs text-muted-foreground">Last {days} Days · Click-Through Rate Is Outbound Clicks Divided by Impressions</p><Metrics values={[["Impressions", summary.totals.tracking.impressions], ["Views", summary.totals.tracking.views], ["Outbound Clicks", summary.totals.tracking.outboundClicks], ["Click-Through Rate", summary.totals.tracking.ctr, true]]} /></section>
          <div className="grid gap-4 lg:grid-cols-2"><AnalyticsTrend points={summary.series} metric="likes" title="Bluesky Like Snapshots" description="Latest cumulative like count at each recorded daily refresh. Missing days are not reconstructed." /><AnalyticsTrend points={summary.series} metric="views" title="Social Wire Views" description="Views recorded each day inside Social Wire during the selected period." /></div>
          <section className="overflow-hidden rounded-2xl border bg-card"><h2 className="p-4 font-semibold">Content Performance</h2>
            {!items.length ? <p className="px-4 pb-8 text-sm text-muted-foreground">No Content Indexed Yet. Select Refresh to Collect Your Posts and Articles.</p> : <div className="overflow-x-auto"><table className="w-full text-left text-xs"><thead className="bg-muted/40"><tr>{["Content", "Likes", "Replies", "Reposts", "Quotes", "Views", "Impressions", "Clicks", "CTR"].map(label => <th key={label} scope="col" className="whitespace-nowrap px-3 py-3 font-medium">{label}</th>)}</tr></thead><tbody>{items.slice(0, visibleCount).map(item => {
              const href = isSocialPostUri(item.uri) ? socialPostPageHref(item.uri) : safeAnalyticsUrl(item.url);
              return <tr key={item.uri} className="border-t"><td className="min-w-56 max-w-96 px-3 py-3"><p className="mb-1 text-[10px] text-muted-foreground">{item.kind === "post" ? "Post" : "Article"} · {item.publishedAt ? new Date(item.publishedAt).toLocaleDateString() : "Date Unavailable"}</p>{href ? <Link href={href} className="line-clamp-2 break-words hover:underline">{item.title || "Untitled Content"}</Link> : <span>{item.title || "Untitled Content"}</span>}</td>{[item.engagement?.likes, item.engagement?.replies, item.engagement?.reposts, item.engagement?.quotes, item.tracking.views, item.tracking.impressions, item.tracking.outboundClicks].map((value, index) => <td key={index} className="px-3 py-3 tabular-nums">{metricLabel(value)}</td>)}<td className="px-3 py-3 tabular-nums">{metricLabel(item.tracking.ctr, true)}</td></tr>;
            })}</tbody></table></div>}
            {items.length > visibleCount || query.hasNextPage ? <div className="p-3"><Button variant="outline" size="sm" disabled={query.isFetchingNextPage} onClick={() => { if (visibleCount >= items.length) void query.fetchNextPage(); setVisibleCount(count => count + 10); }}>{query.isFetchingNextPage ? "Loading…" : "Show More"}</Button></div> : null}
          </section>
        </> : null}
      </div>
    </div>
  </div>;
}

function Metrics({ values }: { values: [string, number | null | undefined, boolean?][] }) {
  return <dl className="grid grid-cols-2 gap-3 lg:grid-cols-4">{values.map(([label, value, percent]) => <div key={label} className="rounded-2xl border bg-card p-4"><dt className="text-xs text-muted-foreground">{label}</dt><dd className="mt-2 text-2xl font-semibold tabular-nums">{metricLabel(value, percent)}</dd></div>)}</dl>;
}
