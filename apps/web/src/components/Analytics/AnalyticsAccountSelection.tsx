"use client";

import { useCallback, useState } from "react";
import Link from "next/link";
import { ChevronDown } from "lucide-react";
import { useBrandAccounts } from "@/hooks/useBrandAccounts";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { aggregateAnalytics } from "@/lib/analytics/aggregateAnalytics";
import { metricLabel, type AnalyticsSummary } from "@/lib/analytics/creatorAnalyticsClient";
import { AnalyticsAccountDetails } from "./AnalyticsWorkspace";
import { AnalyticsAccountIdentity } from "./AnalyticsAccountIdentity";
import { AnalyticsTrend } from "./AnalyticsTrend";

export function AnalyticsAccountSelection({ ownerDid }: { ownerDid: string }) {
  const brands = useBrandAccounts(ownerDid);
  const accounts = [...new Set([ownerDid, ...brands])];
  const [selected, setSelected] = useState([ownerDid]);
  const [days, setDays] = useState(30);
  const active = selected.filter(did => accounts.includes(did));
  return <div className="flex min-h-0 min-w-0 flex-1 flex-col">
    <FeedHeader title="Analytics" subtitle="Your Content and Engagement">
      <div className="relative"><select aria-label="Analytics Time Range" value={days} onChange={event => setDays(Number(event.target.value))} className="h-9 appearance-none rounded-lg border bg-background py-1 pl-3 pr-9 text-sm"><option value={7}>Last 7 Days</option><option value={30}>Last 30 Days</option><option value={90}>Last 90 Days</option></select><ChevronDown aria-hidden="true" className="pointer-events-none absolute right-3 top-3 size-3" /></div>
    </FeedHeader>
    <div className="min-h-0 flex-1 overflow-y-auto p-3 sm:p-5"><div className="mx-auto max-w-6xl space-y-6">
      <fieldset className="space-y-3 rounded-2xl border p-4"><legend className="px-2 font-semibold">Accounts</legend><div className="flex flex-wrap gap-3">{accounts.map(did => <label key={did} className="flex max-w-full cursor-pointer items-center gap-2 rounded-xl border px-3 py-2 text-sm"><input type="checkbox" checked={active.includes(did)} onChange={event => setSelected(previous => event.target.checked ? [...new Set([...previous, did])] : previous.filter(value => value !== did))} /><AnalyticsAccountIdentity did={did} personal={did === ownerDid} /></label>)}</div><Link className="text-xs text-primary hover:underline" href="/brand-accounts">Manage Brand Accounts</Link></fieldset>
      <SelectedAnalytics key={JSON.stringify([ownerDid, days, active])} accounts={active} ownerDid={ownerDid} days={days} />
    </div></div>
  </div>;
}

function SelectedAnalytics({ accounts, ownerDid, days }: { accounts: string[]; ownerDid: string; days: number }) {
  const [summaries, setSummaries] = useState<Record<string, AnalyticsSummary>>({});
  const onSummary = useCallback((did: string, summary: AnalyticsSummary | undefined) => setSummaries(previous => {
    const next = { ...previous }; if (summary) next[did] = summary; else delete next[did]; return next;
  }), []);
  const loaded = accounts.flatMap(did => summaries[did] ? [summaries[did]] : []);
  const combined = aggregateAnalytics(loaded);
  if (!accounts.length) return <p className="py-12 text-center text-muted-foreground">Select Accounts to View Analytics.</p>;
  return <>
    <section aria-label="Combined Account Totals" className="space-y-4 rounded-2xl border p-4"><h2 className="font-semibold">Combined Totals</h2><p className="text-xs text-muted-foreground">{loaded.length} of {accounts.length} selected accounts loaded · Last {days} Days · Available Data Only</p><dl className="grid grid-cols-2 gap-3 lg:grid-cols-4">{[["Likes", combined.totals.engagement.likes], ["Replies", combined.totals.engagement.replies], ["Reposts", combined.totals.engagement.reposts], ["Quotes", combined.totals.engagement.quotes], ["Impressions", combined.totals.tracking.impressions], ["Views", combined.totals.tracking.views], ["Outbound Clicks", combined.totals.tracking.outboundClicks], ["Click-Through Rate", combined.totals.tracking.ctr]].map(([label, value]) => <div key={String(label)}><dt className="text-xs text-muted-foreground">{label}</dt><dd className="mt-1 text-xl font-semibold tabular-nums">{metricLabel(value as number | null, label === "Click-Through Rate")}</dd></div>)}</dl><AnalyticsTrend points={combined.series} metric="views" title="Combined Social Wire Views" description="Available recorded views across the selected accounts. Missing observations remain unavailable." /></section>
    {accounts.map(did => <section key={did} aria-label={`Analytics for ${did}`} className="space-y-3 rounded-2xl border p-4"><h2 className="break-all text-lg font-semibold"><AnalyticsAccountIdentity did={did} personal={did === ownerDid} /></h2><AnalyticsAccountDetails accountDid={did} days={days} onSummary={onSummary} /></section>)}
  </>;
}
