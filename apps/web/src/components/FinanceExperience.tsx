"use client";

import { useLayoutEffect, useRef, useState } from "react";
import { RefreshCw, SlidersHorizontal } from "lucide-react";
import { useFinanceFeed } from "@/hooks/useFinanceFeed";
import { useFeedDisplayPreferences } from "@/hooks/useFeedDisplayPreferences";
import { wireItemToEntryListItem } from "@/lib/wireFeedClient";
import type { EntryListItem } from "@/lib/atprotoClient";
import { WireTopStories } from "@/components/Wire/WireTopStories";
import { WireStoryRail } from "@/components/Wire/WireStoryRail";
import { FinanceFeedPicker } from "@/components/FinanceFeedPicker";
import { FinanceCustomize } from "@/components/FinanceCustomize";
import { FinanceTickerMarquee } from "@/components/FinanceTickerMarquee";
import { FinanceInstrumentOverview } from "@/components/FinanceInstrumentOverview";
import { FinanceFollowingSidebar } from "@/components/FinanceFollowingSidebar";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuCheckboxItem, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { OUTBOUND_WINDOW_FEATURES } from "@/lib/outboundLinks";

export default function FinanceExperience({ feedID = "finance", onFeedChange }: { feedID?: string; onFeedChange?: (id: string) => void }) {
  const finance = useFinanceFeed(feedID);
  const definitions = finance.catalog?.data?.feeds ?? [];
  const [companySearch, setCompanySearch] = useState("");
  const selectedFeed = definitions.find(feed => feed.id === feedID);
  const { preferences, setHideFinancePerformance } = useFeedDisplayPreferences();
  const [customize, setCustomize] = useState(false);
  const [anonymousPerformanceHidden, setAnonymousPerformanceHidden] = useState(false);
  const performanceHidden = finance.signedIn ? preferences.hideFinancePerformance : anonymousPerformanceHidden;
  const changePerformanceVisibility = (hidden: boolean) => {
    if (finance.signedIn) setHideFinancePerformance(hidden);
    else setAnonymousPerformanceHidden(hidden);
  };
  const scroll = useRef<HTMLDivElement>(null);
  const anchor = useRef<{id:string;top:number} | null>(null);

  const saveSelection: typeof finance.saveSelection = async (args) => {
    const host = scroll.current;
    const first = host ? [...host.querySelectorAll<HTMLElement>("[data-wire-story-id]")].find(row => row.getBoundingClientRect().bottom > host.getBoundingClientRect().top) : undefined;
    anchor.current = first ? {id:first.dataset.wireStoryId!,top:first.getBoundingClientRect().top} : null;
    return finance.saveSelection(args);
  };
  useLayoutEffect(() => {
    const pending = anchor.current;
    const host = scroll.current;
    if (!pending || !host) return;
    const row = [...host.querySelectorAll<HTMLElement>("[data-wire-story-id]")].find(item => item.dataset.wireStoryId === pending.id);
    if (row) host.scrollTop += row.getBoundingClientRect().top - pending.top;
    anchor.current = null;
  }, [finance.selections]);

  const stories = finance.items.map(item => ({
    ...wireItemToEntryListItem(item.story, finance.feed.data?.pages[0]?.generatedAt ?? new Date().toISOString()),
    financeItem: item,
  }));
  const openArticle = (_entryId: string, entry?: EntryListItem) => {
    const story = entry?.financeItem?.story;
    if (story) window.open(story.canonicalUrl, "_blank", OUTBOUND_WINDOW_FEATURES);
  };

  return (
    <div key={feedID} ref={scroll} data-finance-scroll className="h-full w-full min-w-0 overflow-x-hidden overflow-y-auto">
      {selectedFeed || feedID === "finance" ? <FinanceTickerMarquee feed={selectedFeed} hidden={performanceHidden} /> : null}
      <div className="grid min-w-0 gap-5 p-4 pt-6 xl:grid-cols-[minmax(0,1fr)_17rem]">
      <div className="@container/finance min-w-0">
      <header className="mb-4 grid grid-cols-2 items-center gap-2 @min-[24rem]/finance:grid-cols-[auto_minmax(0,1fr)_minmax(0,1fr)_2.75rem]">
        <h1 className="col-start-1 row-start-1 min-w-0 break-words text-xl font-semibold @min-[24rem]/finance:max-w-56">{selectedFeed?.title ?? "Finance"}</h1>
        <div className="col-start-1 row-start-2 flex min-w-0 items-center text-sm @min-[24rem]/finance:col-start-2 @min-[24rem]/finance:row-start-1">
          <FinanceFeedPicker definitions={definitions} feedID={feedID} companySearch={companySearch} onFeedChange={onFeedChange} />
        </div>
        <label className="col-start-2 row-start-2 flex min-w-0 items-center text-sm @min-[24rem]/finance:col-start-3 @min-[24rem]/finance:row-start-1">
          <span className="sr-only">Find a Company</span>
          <input type="search" value={companySearch} onChange={event => setCompanySearch(event.target.value)} placeholder="Name, Ticker, or Exchange" className="w-full min-w-0 truncate rounded-md border border-input bg-background px-3 py-3 text-foreground placeholder:truncate " />
        </label>
        <DropdownMenu>
          <DropdownMenuTrigger aria-label="Finance Options" className="col-start-2 row-start-1 flex size-11 justify-self-end items-center justify-center @min-[24rem]/finance:col-start-4 rounded-md border border-input hover:bg-muted focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring">
            <SlidersHorizontal aria-hidden="true" className="size-4" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="min-w-56 max-w-[calc(100vw-2rem)]">
            <DropdownMenuItem className="min-h-11" onClick={() => setCustomize(true)}><SlidersHorizontal aria-hidden="true" />Customize</DropdownMenuItem>
            <DropdownMenuItem className="min-h-11" disabled={finance.refreshing} onClick={() => { void finance.catalog?.refetch(); void finance.refresh(); }}><RefreshCw aria-hidden="true" />Refresh</DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuCheckboxItem className="min-h-11" checked={performanceHidden} onCheckedChange={changePerformanceVisibility}>Hide Performance Data</DropdownMenuCheckboxItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </header>
      {companySearch.trim() && !definitions.some(feed => feed.kind === "instrument" && feed.title.toLocaleLowerCase().includes(companySearch.trim().toLocaleLowerCase())) ? <p role="status" className="mb-4 text-sm text-muted-foreground">No companies match your search.</p> : null}
      {selectedFeed?.description ? <p className="mb-4 text-sm text-muted-foreground">{selectedFeed.description}</p> : null}
      {finance.catalog?.error ? <p role="alert" className="mb-4 text-sm text-destructive">Feed choices could not load. Try Refresh.</p> : null}
      {finance.error ? <p role="alert" className="mb-4 text-sm text-destructive">{finance.error instanceof Error ? finance.error.message : "Finance could not load. Try Refresh."}</p> : null}
      {finance.suspended ? <p className="mb-4 text-sm text-muted-foreground">{feedID === "finance" ? "Your interests have reordered these articles. Refresh to load a new edition." : "Your interests have changed. Refresh to update this feed."}</p> : null}
      {selectedFeed?.kind === "instrument" && selectedFeed.instrumentIDs.length === 1 ? <FinanceInstrumentOverview key={feedID} feed={selectedFeed} items={finance.items} hidden={performanceHidden} widgetsEnabled={finance.catalog?.data?.widgetsEnabled ?? false} /> : null}
      {finance.isLoading && !finance.items.length ? <p role="status">Loading Finance…</p> : null}
      <div className="-mx-4 min-w-0 space-y-7 pb-4">
        <WireTopStories stories={stories.slice(0, 4)} onSelect={openArticle} editionLabel={selectedFeed?.title ?? "Finance"} />
        <WireStoryRail
          id="finance-more-stories"
          behindSidebar
          eyebrow="Keep Reading"
          title="More Stories"
          stories={stories.slice(4)}
          onSelect={openArticle}
          onNearEnd={finance.feed.hasNextPage && !finance.suspended && !finance.feed.isFetchingNextPage ? () => void finance.feed.fetchNextPage() : undefined}
        />
      </div>
      {!finance.isLoading && !finance.items.length && !finance.error ? <p>{feedID === "finance" ? "No finance stories are available right now." : "No matching stories are available right now. Try Refresh later or choose another feed."}</p> : null}
      {finance.feed.hasNextPage && !finance.suspended ? <Button className="mt-4" variant="outline" disabled={finance.feed.isFetchingNextPage} onClick={() => void finance.feed.fetchNextPage()}>Load More</Button> : null}
      <FinanceCustomize key={customize ? "open" : "closed"} open={customize} onOpenChange={setCustomize} selections={finance.selections} save={saveSelection} saving={finance.saving} signedIn={finance.signedIn} />
      </div>
      <FinanceFollowingSidebar definitions={definitions} selections={finance.selections} loading={finance.catalog?.isPending || finance.selectionsLoading} error={!!finance.catalog?.error || !!finance.selectionsError} feedID={feedID} onFeedChange={onFeedChange} />
      </div>
    </div>
  );
}
