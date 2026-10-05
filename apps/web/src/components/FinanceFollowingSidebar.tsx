"use client";

import { ChartNoAxesCombined } from "lucide-react";
import { useViewportSidebar } from "@/hooks/useViewportSidebar";
import type { FinanceFeedDefinition, FinanceSelection } from "@/lib/financeFeedClient";

export function FinanceFollowingSidebar({ definitions, selections, loading = false, error = false, feedID, onFeedChange }: {
  definitions: readonly FinanceFeedDefinition[]; selections: readonly FinanceSelection[]; loading?: boolean; error?: boolean; feedID: string; onFeedChange?: (id: string) => void;
}) {
  const sidebar = useViewportSidebar("[data-finance-scroll]");
  const followed = new Set(selections.filter(selection => selection.kind === "instrument").map(selection => selection.reference));
  const rows = definitions.filter(feed => feed.kind === "instrument" && feed.instrumentIDs.length === 1 && followed.has(feed.instrumentIDs[0])).sort((a, b) => a.title.localeCompare(b.title));
  const link = (id: string, title: string, all = false) => <a href={all ? "/read?feed=finance" : `/read?${new URLSearchParams({ feed: "finance", financeFeed: id })}`} aria-current={feedID === id ? "page" : undefined} onClick={event => {
    if (!onFeedChange || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault(); onFeedChange(id);
  }} className={`flex min-h-11 min-w-0 items-center gap-2 rounded-md px-2 py-2 text-sm hover:bg-muted focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring aria-[current=page]:bg-accent aria-[current=page]:text-accent-foreground ${all ? "mt-3 border border-input px-3 font-medium" : ""}`}><ChartNoAxesCombined aria-hidden="true" className="size-4 shrink-0" /><span className="min-w-0 break-words">{title}</span></a>;
  return <aside ref={sidebar} aria-labelledby="finance-following-heading" className="relative z-10 hidden self-start rounded-2xl border border-border/70 bg-background/70 p-4 backdrop-blur-md xl:sticky xl:top-4 xl:block xl:max-h-[calc(100svh-var(--environment-banner-height,0px)-3rem)] xl:overflow-y-auto xl:overscroll-contain dark:border-border/55">
    <h2 id="finance-following-heading" className="text-lg font-semibold">Following in Finance</h2>
    {link("finance", "All Finance", true)}
    {loading ? <p role="status" className="mt-3 text-sm text-muted-foreground">Loading Your Securities…</p> : null}
    {error ? <p role="status" className="mt-3 text-sm text-muted-foreground">Your securities could not load. Try Refresh.</p> : null}
    {!loading && !error && !rows.length ? <p className="mt-3 text-sm text-muted-foreground">Add securities in Customize to see them here.</p> : null}
    {rows.length ? <section className="mt-4"><h3 className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">Securities</h3><ul className="space-y-1">{rows.map(feed => <li key={feed.id}>{link(feed.id, feed.title)}</li>)}</ul></section> : null}
  </aside>;
}
