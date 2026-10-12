"use client";

import { floatingSidebarClassName, floatingSidebarRowClassName } from "@/components/shared/floatingSidebarStyles";
import { Clock, Download, ListMusic, Search, Scissors, Trash2 } from "lucide-react";
import { ContextMenu, ContextMenuContent, ContextMenuItem, ContextMenuTrigger } from "@/components/ui/context-menu";
import { PodcastArtwork } from "./PodcastArtwork";
import type { PodcastShow } from "@/lib/podcasts/client";
import type { PodcastFeed } from "@/lib/podcasts/library";

export function PodcastLibrarySidebar({ feed, showId, shows, subscriptions, downloadCount, queueCount, onSelect, discoverActive = false, onDiscover, onUnsubscribe, busy = false }: {
  feed: PodcastFeed;
  showId: string | null;
  shows: PodcastShow[];
  subscriptions: string[];
  downloadCount: number;
  queueCount: number;
  onSelect: (feed: PodcastFeed, showId?: string) => void;
  discoverActive?: boolean;
  onDiscover?: () => void;
  onUnsubscribe?: (show: PodcastShow) => void;
  busy?: boolean;
}) {
  const rows = [
    { id: "recent" as const, label: "Recently Added", Icon: Clock },
    { id: "downloads" as const, label: "Downloaded", Icon: Download, count: downloadCount },
    { id: "queue" as const, label: "Up Next", Icon: ListMusic, count: queueCount },
    { id: "clips" as const, label: "Clips", Icon: Scissors },
  ];
  const subscribed = shows.filter((show) => subscriptions.includes(show.id));
  return (
    <aside aria-label="Podcast Library" className={`${floatingSidebarClassName} w-full space-y-3 lg:min-h-0 lg:flex-1 lg:overflow-y-auto lg:overscroll-contain`}>
      <nav aria-label="Podcast Feeds" className="space-y-1">
        {onDiscover ? <button type="button" aria-current={discoverActive ? "page" : undefined}
          onClick={onDiscover}
          className={`${floatingSidebarRowClassName} w-full text-left ${discoverActive ? "bg-accent font-medium" : "hover:bg-accent/60"}`}>
          <Search className="size-4 shrink-0" aria-hidden="true" /><span>Search</span>
        </button> : null}
        {rows.map(({ id, label, Icon, count }) => (
          <button key={id} type="button" aria-current={!discoverActive && feed === id ? "page" : undefined}
            onClick={() => onSelect(id)}
            className={`${floatingSidebarRowClassName} w-full text-left ${!discoverActive && feed === id ? "bg-accent font-medium" : "hover:bg-accent/60"}`}>
            <Icon className="size-4 shrink-0" aria-hidden="true" /><span className="flex-1">{label}</span>
            {count !== undefined ? <span className="text-xs tabular-nums text-muted-foreground">{count}</span> : null}
          </button>
        ))}
      </nav>
      <section aria-label="Subscribed Shows">
        <h2 className="mb-1 px-2 text-xs font-medium text-muted-foreground">Subscribed Shows</h2>
        {subscribed.length ? <ul className="space-y-1">{subscribed.map((show) => (
          <li key={show.id}>
            <ContextMenu>
              <ContextMenuTrigger render={<button type="button" />} aria-current={!discoverActive && feed === "show" && showId === show.id ? "page" : undefined}
                onClick={() => onSelect("show", show.id)}
                className={`${floatingSidebarRowClassName} w-full text-left ${!discoverActive && feed === "show" && showId === show.id ? "bg-accent" : "hover:bg-accent/60"}`}>
                <PodcastArtwork src={show.artworkUrl} alt="" size={32} className="size-8 rounded" />
                <span className="min-w-0 break-words">{show.title}{show.visibility === "private" ? <span className="block text-xs text-muted-foreground">Private Feed</span> : null}</span>
              </ContextMenuTrigger>
              {onUnsubscribe ? <ContextMenuContent>
                <ContextMenuItem variant="destructive" disabled={busy} onClick={() => onUnsubscribe(show)}>
                  <Trash2 aria-hidden="true" />Unsubscribe
                </ContextMenuItem>
              </ContextMenuContent> : null}
            </ContextMenu>
          </li>
        ))}</ul> : <p className="px-2 text-sm text-muted-foreground">Your Subscribed Shows Will Appear Here</p>}
      </section>
    </aside>
  );
}
