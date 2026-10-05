"use client";

import { useLayoutEffect, useMemo, useRef, useState } from "react";
import { RefreshCw, SlidersHorizontal } from "lucide-react";
import { useSportsFeed } from "@/hooks/useSportsFeed";
import { useFeedDisplayPreferences } from "@/hooks/useFeedDisplayPreferences";
import { wireItemToEntryListItem } from "@/lib/wireFeedClient";
import type { EntryListItem } from "@/lib/atprotoClient";
import { WireTopStories } from "@/components/Wire/WireTopStories";
import { WireStoryRail } from "@/components/Wire/WireStoryRail";
import { SportsFeedPicker } from "@/components/SportsFeedPicker";
import { SportsFeedFollowButton } from "@/components/SportsFeedFollowButton";
import { SportsCustomize } from "@/components/SportsCustomize";
import { SportsFollowingSidebar } from "@/components/SportsFollowingSidebar";
import { SportsEventsStrip } from "@/components/SportsEventsStrip";
import { SportsEntityOverview } from "@/components/SportsEntityOverview";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuCheckboxItem, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { OUTBOUND_WINDOW_FEATURES } from "@/lib/outboundLinks";

import { displaySportsFeedTitle, sportsFeedSearchText } from "@/lib/sportsDisplayNames";
import { useSportsDisplayLocale } from "@/hooks/useSportsDisplayLocale";

export default function SportsExperience({ feedID = "sports", onFeedChange }: { feedID?: string; onFeedChange?: (id: string) => void }) {
  const locale = useSportsDisplayLocale();
  const sports = useSportsFeed(feedID);
  const { catalogEntities, entitiesByID, definitions } = useMemo(() => {
    const catalogEntities = sports.catalog.data?.entities ?? [];
    const entitiesByID = new Map(catalogEntities.map(entity => [entity.id, entity]));
    const definitions = (sports.catalog.data?.feeds ?? []).filter(feed => feed.entityIDs.every(id => entitiesByID.get(id)?.active !== false)).map(feed => ({ ...feed, searchAliases: feed.entityIDs.flatMap(id => entitiesByID.get(id)?.aliases ?? []) }));
    return { catalogEntities, entitiesByID, definitions };
  }, [sports.catalog.data]);
  const [entitySearch, setCompanySearch] = useState("");
  const selectedFeed = definitions.find(feed => feed.id === feedID);
  const followEntity = selectedFeed?.kind !== "global" && selectedFeed?.entityIDs.length === 1
    ? entitiesByID.get(selectedFeed.entityIDs[0]) : undefined;
  const { preferences, setHideSportsScores, isLoading: preferenceLoading, isPending: preferencePending, error: preferenceError } = useFeedDisplayPreferences();
  const [customize, setCustomize] = useState(false);
  const [anonymousPerformanceHidden, setAnonymousPerformanceHidden] = useState(false);
  const performanceHidden = sports.signedIn ? preferences.hideSportsScores : anonymousPerformanceHidden;
  const changePerformanceVisibility = (hidden: boolean) => {
    if (sports.signedIn) setHideSportsScores(hidden);
    else setAnonymousPerformanceHidden(hidden);
  };
  const scroll = useRef<HTMLDivElement>(null);
  const anchor = useRef<{id:string;top:number} | null>(null);

  const saveSelection: typeof sports.saveSelection = async (args) => {
    const host = scroll.current;
    const first = host ? [...host.querySelectorAll<HTMLElement>("[data-wire-story-id]")].find(row => row.getBoundingClientRect().bottom > host.getBoundingClientRect().top) : undefined;
    anchor.current = first ? {id:first.dataset.wireStoryId!,top:first.getBoundingClientRect().top} : null;
    return sports.saveSelection(args);
  };
  useLayoutEffect(() => {
    const pending = anchor.current;
    const host = scroll.current;
    if (!pending || !host) return;
    const row = [...host.querySelectorAll<HTMLElement>("[data-wire-story-id]")].find(item => item.dataset.wireStoryId === pending.id);
    if (row) host.scrollTop += row.getBoundingClientRect().top - pending.top;
    anchor.current = null;
  }, [sports.selections]);

  const stories = sports.items.map(item => ({
    ...wireItemToEntryListItem(item.story, sports.feed.data?.pages[0]?.generatedAt ?? new Date().toISOString()),
    sportsItem: item,
  }));
  const openArticle = (_entryId: string, entry?: EntryListItem) => {
    const story = entry?.sportsItem?.story;
    if (story) window.open(story.canonicalUrl, "_blank", OUTBOUND_WINDOW_FEATURES);
  };

  return (
    <div key={feedID} ref={scroll} data-sports-scroll className="h-full w-full min-w-0 overflow-x-hidden overflow-y-auto">
      {!followEntity && (sports.catalog.data?.eventsEnabled || (feedID === "sports" && sports.catalog.isPending && !sports.catalog.data)) ? <SportsEventsStrip feedID={feedID} hidden={performanceHidden} entities={catalogEntities} selections={sports.selections} viewerDID={sports.viewerDID ?? "public"} selectionsLoading={sports.selectionsLoading || !!sports.selectionsError} catalogLoading={!sports.catalog.data} /> : null}
      <div className="grid min-w-0 gap-5 p-4 pt-6 xl:grid-cols-[minmax(0,1fr)_17rem]">
      <div className="@container/sports min-w-0">
      <header className="mb-4 grid grid-cols-2 items-center gap-2 @min-[24rem]/sports:grid-cols-[auto_minmax(0,1fr)_minmax(0,1fr)_2.75rem]">
        <h1 className="col-start-1 row-start-1 min-w-0 break-words text-xl font-semibold @min-[24rem]/sports:max-w-56">{selectedFeed ? displaySportsFeedTitle(selectedFeed, locale) : "Sports"}</h1>
        <div className="col-start-1 row-start-2 flex min-w-0 items-center text-sm @min-[24rem]/sports:col-start-2 @min-[24rem]/sports:row-start-1">
          <SportsFeedPicker entities={catalogEntities} definitions={definitions} feedID={feedID} entitySearch={entitySearch} onFeedChange={onFeedChange} />
        </div>
        <label className="col-start-2 row-start-2 flex min-w-0 items-center text-sm @min-[24rem]/sports:col-start-3 @min-[24rem]/sports:row-start-1">
          <span className="sr-only">Find a Sport, Team, or Person</span>
          <input type="search" value={entitySearch} onChange={event => setCompanySearch(event.target.value)} placeholder="Sport, Team, or Person" className="w-full min-w-0 truncate rounded-md border border-input bg-background px-3 py-3 text-foreground placeholder:truncate " />
        </label>
        <DropdownMenu>
          <DropdownMenuTrigger aria-label="Sports Options" className="col-start-2 row-start-1 flex size-11 justify-self-end items-center justify-center @min-[24rem]/sports:col-start-4 rounded-md border border-input hover:bg-muted focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring">
            <SlidersHorizontal aria-hidden="true" className="size-4" />
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="min-w-56 max-w-[calc(100vw-2rem)]">
            <DropdownMenuItem className="min-h-11" onClick={() => setCustomize(true)}><SlidersHorizontal aria-hidden="true" />Customize</DropdownMenuItem>
            <DropdownMenuItem className="min-h-11" disabled={sports.refreshing} onClick={() => { void sports.catalog?.refetch(); void sports.refresh(); }}><RefreshCw aria-hidden="true" />Refresh</DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuCheckboxItem className="min-h-11" checked={performanceHidden} disabled={preferencePending || (sports.signedIn && preferenceLoading)} onCheckedChange={changePerformanceVisibility}>Hide Scores</DropdownMenuCheckboxItem>
            <p className="px-2 py-1.5 text-xs text-muted-foreground">Hides event scores and results. Article headlines and images may reveal results.</p>
          </DropdownMenuContent>
        </DropdownMenu>
      </header>
      {entitySearch.trim() && !definitions.some(feed => feed.kind !== "global" && sportsFeedSearchText(feed, locale).includes(entitySearch.trim().toLocaleLowerCase())) ? <p role="status" className="mb-4 text-sm text-muted-foreground">No feeds match your search.</p> : null}
      {selectedFeed?.description || followEntity ? <div className="mb-4 flex flex-wrap items-center gap-3">
        {selectedFeed?.description ? <p className="min-w-0 flex-1 text-sm text-muted-foreground">{selectedFeed.description.replace(`Stories matching ${selectedFeed.title}`, `Stories matching ${displaySportsFeedTitle(selectedFeed, locale)}`)}</p> : null}
        <SportsFeedFollowButton key={`${sports.viewerDID ?? "public"}:${followEntity?.id ?? "global"}`} entity={followEntity}
          selections={sports.selections} save={saveSelection} saving={sports.saving}
          loading={sports.selectionsLoading || !!sports.selectionsError} signedIn={sports.signedIn} viewerDID={sports.viewerDID} />
      </div> : null}
      {preferencePending ? <p role="status" className="mb-4 text-sm text-muted-foreground">Saving Score Preference…</p> : null}
      {preferenceError ? <p role="alert" className="mb-4 text-sm text-destructive">Score preference could not save. {preferenceError instanceof Error ? preferenceError.message : "Try again."}</p> : null}
      {sports.catalog?.error ? <p role="alert" className="mb-4 text-sm text-destructive">Feed choices could not load. Try Refresh.</p> : null}
      {sports.error ? <p role="alert" className="mb-4 text-sm text-destructive">{sports.error instanceof Error ? sports.error.message : "Sports could not load. Try Refresh."}</p> : null}
      {sports.suspended ? <p className="mb-4 text-sm text-muted-foreground">{feedID === "sports" ? "Your interests have reordered these articles. Refresh to load a new edition." : "Your interests have changed. Refresh to update this feed."}</p> : null}
      {followEntity ? <SportsEntityOverview key={`${sports.viewerDID ?? "public"}:${feedID}`} feedID={feedID} entity={followEntity} entities={catalogEntities} hidden={performanceHidden} eventsEnabled={sports.catalog.data?.eventsEnabled ?? false} viewerDID={sports.viewerDID ?? "public"} /> : null}
      {sports.isLoading && !sports.items.length ? <p role="status">Loading Sports…</p> : null}
      <div className="-mx-4 min-w-0 space-y-7 pb-4">
        <WireTopStories stories={stories.slice(0, 4)} onSelect={openArticle} editionLabel={selectedFeed ? displaySportsFeedTitle(selectedFeed, locale) : "Sports"} />
        <WireStoryRail
          id="sports-more-stories"
          behindSidebar
          eyebrow="Keep Reading"
          title="More Stories"
          stories={stories.slice(4)}
          onSelect={openArticle}
          onNearEnd={sports.feed.hasNextPage && !sports.suspended && !sports.feed.isFetchingNextPage ? () => void sports.feed.fetchNextPage() : undefined}
        />
      </div>
      {!sports.isLoading && !sports.items.length && !sports.error ? <p>{feedID === "sports" ? "No sports stories are available right now." : "No matching stories are available right now. Try Refresh later or choose another feed."}</p> : null}
      {sports.feed.hasNextPage && !sports.suspended ? <Button className="mt-4" variant="outline" disabled={sports.feed.isFetchingNextPage} onClick={() => void sports.feed.fetchNextPage()}>Load More</Button> : null}
      <SportsCustomize key={customize ? "open" : "closed"} open={customize} onOpenChange={setCustomize} selections={sports.selections} save={saveSelection} saving={sports.saving} signedIn={sports.signedIn} viewerDID={sports.viewerDID} />
      </div>
      <SportsFollowingSidebar entities={catalogEntities} definitions={definitions} selections={sports.selections} loading={sports.catalog.isPending || sports.selectionsLoading} error={!!sports.catalog.error || !!sports.selectionsError} feedID={feedID} onFeedChange={onFeedChange} />
      </div>
    </div>
  );
}
