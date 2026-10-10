"use client";

import { ChartNoAxesCombined } from "lucide-react";
import { floatingSidebarClassName, floatingSidebarRowClassName } from "@/components/shared/floatingSidebarStyles";
import { useViewportSidebar } from "@/hooks/useViewportSidebar";
import type { FinanceFeedDefinition, FinanceSelection } from "@/lib/financeFeedClient";

export function FinanceFollowingSidebar({ definitions, selections, loading = false, error = false, feedID, onFeedChange }: {
  definitions: readonly FinanceFeedDefinition[]; selections: readonly FinanceSelection[]; loading?: boolean; error?: boolean; feedID: string; onFeedChange?: (id: string) => void;
}) {
  const sidebar = useViewportSidebar("[data-finance-scroll]");
  const followed = new Set(selections.filter(selection => selection.kind === "instrument").map(selection => selection.reference));
  const rows = definitions.filter(feed => feed.kind === "instrument" && feed.instrumentIDs.length === 1 && followed.has(feed.instrumentIDs[0])).sort((a, b) => a.title.localeCompare(b.title));
  const followedSectors = new Set(selections.filter(selection => selection.kind === "sector").map(selection => selection.reference));
  const sectorRows = definitions.filter(feed => feed.kind === "industry" && feed.sectorIDs.length === 1 && followedSectors.has(feed.sectorIDs[0])).sort((a, b) => a.title.localeCompare(b.title));
  const link = (id: string, title: string, all = false) => <a href={all ? "/read?feed=finance" : `/read?${new URLSearchParams({ feed: "finance", financeFeed: id })}`} aria-current={feedID === id ? "page" : undefined} onClick={event => {
    if (!onFeedChange || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault(); onFeedChange(id);
  }} className={`${floatingSidebarRowClassName} hover:bg-muted focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring aria-[current=page]:bg-accent aria-[current=page]:text-accent-foreground ${all ? "mt-2 font-medium" : ""}`}><ChartNoAxesCombined aria-hidden="true" className="size-4 shrink-0" /><span className="min-w-0 break-words">{title}</span></a>;
  return <aside ref={sidebar} aria-labelledby="finance-following-heading" className={`${floatingSidebarClassName} relative z-10 hidden xl:sticky xl:top-4 xl:block xl:max-h-[calc(100svh-var(--environment-banner-height,0px)-3rem)] xl:overflow-y-auto xl:overscroll-contain`}>
    <h2 id="finance-following-heading" className="text-base font-semibold">Following in Finance</h2>
    {link("finance", "All Finance", true)}
    {loading ? <p role="status" className="mt-2 text-sm text-muted-foreground">Loading Your Interests…</p> : null}
    {error ? <p role="status" className="mt-2 text-sm text-muted-foreground">Your interests could not load. Try Refresh.</p> : null}
    {!loading && !error && !rows.length && !sectorRows.length ? <p className="mt-2 text-sm text-muted-foreground">Add sectors or securities in Customize to see them here.</p> : null}
    {sectorRows.length ? <section className="mt-3"><h3 className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">Sectors</h3><ul className="space-y-1">{sectorRows.map(feed => <li key={feed.id}>{link(feed.id, feed.title)}</li>)}</ul></section> : null}
    {rows.length ? <section className="mt-3"><h3 className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">Securities</h3><ul className="space-y-1">{rows.map(feed => <li key={feed.id}>{link(feed.id, feed.title.split(" · ", 2).join(" · "))}</li>)}</ul></section> : null}
  </aside>;
}
