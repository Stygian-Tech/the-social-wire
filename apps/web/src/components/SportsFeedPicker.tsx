"use client";

import { createElement, useEffect, useMemo, useRef, useState } from "react";
import { Popover } from "@base-ui/react/popover";
import { Trophy, PersonStanding, UsersRound, Check, ChevronDown, ChevronRight, ArrowLeft } from "lucide-react";
import { sportsFeedPickerTree, sportsPickerSearch, type SportsPickerNode } from "@/lib/sportsFeedPickerTree";
import type { SportsEntity, SportsFeedDefinition } from "@/lib/sportsFeedClient";
import type { SportsPickerFeedDefinition } from "@/lib/sportsFeedPickerGroups";
import { displaySportsFeedTitle } from "@/lib/sportsDisplayNames";
import { useSportsDisplayLocale } from "@/hooks/useSportsDisplayLocale";

function feedIcon(feed: SportsFeedDefinition | undefined) {
  const Icon = ["team", "national-side", "ncaa-team"].includes(feed?.kind ?? "") ? UsersRound : feed?.kind === "athlete" || feed?.kind === "driver" ? PersonStanding : Trophy;
  return createElement(Icon, { "aria-hidden": true, className: "size-4 shrink-0" });
}
const emptyEntities: readonly SportsEntity[] = [];
const emptyTree: SportsPickerNode = { id: "root", label: "Sports", children: [], feeds: [] };
const emptySearch = { feeds: [] as SportsPickerFeedDefinition[], total: 0 };
const rowClass = "flex min-h-11 w-full min-w-0 items-center gap-2 rounded-md px-2 py-2 text-left text-sm hover:bg-accent hover:text-accent-foreground focus-visible:bg-accent focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring";

export function SportsFeedPicker({definitions, entities = emptyEntities, feedID, entitySearch, onFeedChange}: {
  definitions: SportsPickerFeedDefinition[];
  entities?: readonly SportsEntity[];
  feedID: string;
  entitySearch: string;
  onFeedChange?: (id: string) => void;
}) {
  const locale = useSportsDisplayLocale();
  const selected = definitions.find(feed=>feed.id===feedID);
  const [open,setOpen] = useState(false);
  const [path,setPath] = useState<string[]>([]);
  const [visibleCount,setVisibleCount] = useState(25);
  const navigation = useRef<HTMLElement>(null);
  const previousNode = useRef("root");
  const searching = entitySearch.trim().length > 0;
  const browse = open && !searching;
  const findMatches = open && searching;
  const tree = useMemo(()=>browse ? sportsFeedPickerTree(definitions,entities,locale) : emptyTree,[browse,definitions,entities,locale]);
  const search = useMemo(()=>findMatches ? sportsPickerSearch(definitions,entitySearch,locale) : emptySearch,[findMatches,definitions,entitySearch,locale]);
  const trail = [tree];
  for (const id of path) {
    const child = trail.at(-1)!.children.find(node=>node.id===id);
    if (!child) break;
    trail.push(child);
  }
  const node = trail.at(-1)!;
  useEffect(()=>{
    if (open && previousNode.current !== node.id) navigation.current?.querySelector<HTMLButtonElement>("button")?.focus();
    previousNode.current = node.id;
  },[open,node.id]);
  const selectFeed = (id:string) => { onFeedChange?.(id); setOpen(false); };
  const feedRow = (feed:SportsFeedDefinition) => <button key={feed.id} type="button" aria-current={feed.id===feedID?"true":undefined} className={rowClass} onClick={()=>selectFeed(feed.id)}>{feedIcon(feed)}<span className="min-w-0 flex-1 break-words">{feed.kind==="sport"||feed.kind==="competition" ? `All ${displaySportsFeedTitle(feed,locale)}` : displaySportsFeedTitle(feed,locale)}</span>{feed.id===feedID?<Check aria-hidden="true" className="size-4 shrink-0"/>:null}</button>;
  return <Popover.Root open={open} onOpenChange={value=>{setOpen(value);if(value){setPath([]);setVisibleCount(25);}}}>
    <Popover.Trigger aria-label="Sports Feed" className="flex w-full min-w-0 items-center gap-2 rounded-md border border-input bg-background px-3 py-3 text-left text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">{feedIcon(selected)}<span className="min-w-0 flex-1 truncate">{selected?displaySportsFeedTitle(selected,locale):definitions.length?"Unavailable Feed":"Sports"}</span><ChevronDown aria-hidden="true" className="size-4 shrink-0"/></Popover.Trigger>
    <Popover.Portal><Popover.Positioner align="start" side="bottom" sideOffset={6} className="z-50 max-w-[calc(100vw-2rem)]"><Popover.Popup aria-label="Choose a Sports Feed" className="w-(--anchor-width) min-w-[min(20rem,calc(100vw-2rem))] max-w-[calc(100vw-2rem)] overflow-hidden rounded-lg border bg-popover text-popover-foreground shadow-md outline-none">
      <div className="border-b p-2">
        {!searching && trail.length>1 ? <button type="button" className={rowClass} onClick={()=>{setPath(trail.slice(1,-1).map(part=>part.id));setVisibleCount(25);}}><ArrowLeft aria-hidden="true" className="size-4"/>Back</button>:null}
        <p className="px-2 py-1 text-xs font-semibold text-muted-foreground">{searching?"Search Results":trail.map(part=>part.label).join(" › ")}</p>
      </div>
      <nav ref={navigation} aria-label={searching?"Matching Sports Feeds":`${node.label} Feeds`} className="max-h-[min(24rem,var(--available-height))] overflow-y-auto overscroll-contain p-1">
        {searching ? <>{definitions.filter(feed=>feed.kind === "global").map(feedRow)}{search.feeds.map(feedRow)}{!search.total?<p role="status" className="px-2 py-3 text-sm text-muted-foreground">No Feeds Match Your Search.</p>:null}{search.total>search.feeds.length?<p role="status" className="px-2 py-3 text-xs text-muted-foreground">Showing {search.feeds.length} of {search.total} Matches. Refine Your Search.</p>:null}</> : <>{node.feeds.slice(0,visibleCount).map(feedRow)}{node.children.map(child=><button key={child.id} type="button" className={rowClass} onClick={()=>{setPath([...trail.slice(1).map(part=>part.id),child.id]);setVisibleCount(25);}}><Trophy aria-hidden="true" className="size-4 shrink-0"/><span className="min-w-0 flex-1 break-words">{child.label.replaceAll(" ", "\u00a0")}</span><ChevronRight aria-hidden="true" className="size-4 shrink-0"/></button>)}{node.feeds.length>visibleCount?<button type="button" className={rowClass} onClick={()=>setVisibleCount(count=>count+25)}>Show More ({node.feeds.length-visibleCount} Remaining)</button>:null}</>}
      </nav>
    </Popover.Popup></Popover.Positioner></Popover.Portal>
  </Popover.Root>;
}
