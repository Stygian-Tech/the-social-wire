"use client";

import { Trophy, Archive, Bookmark, ChartNoAxesCombined, List, MoreHorizontal, Network, Newspaper, Rss, Users } from "lucide-react";

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import type { ReaderNavigationFeed } from "@/lib/feedPreferences";
import { cn } from "@/lib/utils";
import { WireBetaBadge } from "@/components/Wire/WireBetaBadge";

const FEED_ITEMS = [
  { feed: "wire", label: "The Wire", icon: Rss },
  { feed: "circle", label: "Your Circle", icon: Network },
  { feed: "sports", label: "Sports", icon: Trophy },
  { feed: "finance", label: "Finance", icon: ChartNoAxesCombined },
  { feed: "readLater", label: "Saved", icon: Bookmark },
  { feed: "archive", label: "Archive", icon: Archive },
  { feed: "subscribed", label: "Subscribed", icon: Newspaper },
  { feed: "following", label: "Following", icon: Users },
] as const;

// Match the four default iOS primary slots; remaining destinations stay in More.
const PRIMARY_FEEDS: readonly ReaderNavigationFeed[] = ["wire", "circle", "subscribed", "following"];
const navigationButtonClass = "flex min-h-16 min-w-0 flex-col items-center justify-center gap-0.5 px-1 text-[11px] font-medium text-muted-foreground transition-colors hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring";

export function MobileFeedNavigation({
  currentFeed,
  visibleFeeds,
  onSelect,
  readLaterLabel = "Saved",
  onOpenLists,
  listsActive = false,
}: {
  currentFeed: ReaderNavigationFeed | null;
  visibleFeeds: Set<ReaderNavigationFeed>;
  onSelect: (feed: ReaderNavigationFeed) => void;
  readLaterLabel?: string;
  onOpenLists?: () => void;
  listsActive?: boolean;
}) {
  const items = FEED_ITEMS.filter(({ feed }) => visibleFeeds.has(feed));
  if (items.length === 0 && !onOpenLists) return null;
  const orderedItems = [
    ...PRIMARY_FEEDS.flatMap((feed) => items.filter((item) => item.feed === feed)),
    ...items.filter((item) => !PRIMARY_FEEDS.includes(item.feed)),
  ];
  const primaryItems = orderedItems.slice(0, 4);
  const overflowItems = orderedItems.slice(4);
  const overflowActive = listsActive || overflowItems.some(({ feed }) => feed === currentFeed);

  return (
    <nav
      aria-label="Feed Navigation"
      className="fixed inset-x-0 bottom-0 z-40 grid border-t border-border/70 bg-background/95 px-2 pb-[env(safe-area-inset-bottom)] backdrop-blur-md md:hidden"
      style={{ gridTemplateColumns: `repeat(${primaryItems.length + (overflowItems.length > 0 || onOpenLists ? 1 : 0)}, minmax(0, 1fr))` }}
    >
      {primaryItems.map(({ feed, label: defaultLabel, icon: Icon }) => {
        const label = feed === "readLater" ? readLaterLabel : defaultLabel;
        const active = currentFeed === feed;
        return (
          <button
            key={feed}
            type="button"
            aria-label={
              feed === "wire" || feed === "circle" || feed === "finance" || feed === "sports" ? `${label}, Beta` : label
            }
            aria-current={active ? "page" : undefined}
            className={cn(
              navigationButtonClass,
              active && "text-[var(--purple-foreground)]",
            )}
            onClick={() => onSelect(feed)}
          >
            <Icon className="size-5" aria-hidden="true" />
            <span className="w-full truncate text-center">{label}</span>
            <span className="flex h-2.5 items-center">
              {feed === "wire" || feed === "circle" || feed === "finance" || feed === "sports" ? (
                <WireBetaBadge className="px-1 py-px text-[7px]" />
              ) : null}
            </span>
          </button>
        );
      })}
      {overflowItems.length > 0 || onOpenLists ? (
        <DropdownMenu>
          <DropdownMenuTrigger
            aria-label="More Feeds"
            aria-current={overflowActive ? "page" : undefined}
            className={cn(navigationButtonClass, overflowActive && "text-[var(--purple-foreground)]")}
          >
            <MoreHorizontal className="size-5" aria-hidden="true" />
            <span className="w-full truncate text-center">More</span>
            <span className="h-2.5" aria-hidden="true" />
          </DropdownMenuTrigger>
          <DropdownMenuContent side="top" align="end" className="min-w-48 max-w-[calc(100vw-1rem)]">
            {onOpenLists ? <DropdownMenuItem aria-label="Lists" aria-current={listsActive ? "page" : undefined} className="min-h-11" onClick={onOpenLists}><List className="size-4" aria-hidden="true" /><span>Lists</span></DropdownMenuItem> : null}
            {overflowItems.map(({ feed, label: defaultLabel, icon: Icon }) => {
              const label = feed === "readLater" ? readLaterLabel : defaultLabel;
              return (
                <DropdownMenuItem
                  key={feed}
                  aria-label={feed === "wire" || feed === "circle" || feed === "finance" || feed === "sports" ? `${label}, Beta` : label}
                  aria-current={currentFeed === feed ? "page" : undefined}
                  className={cn("min-h-11", currentFeed === feed && "text-[var(--purple-foreground)]")}
                  onClick={() => onSelect(feed)}
                >
                  <Icon className="size-4" aria-hidden="true" />
                  <span className="flex-1 truncate">{label}</span>
                  {feed === "wire" || feed === "circle" || feed === "finance" || feed === "sports" ? <WireBetaBadge /> : null}
                </DropdownMenuItem>
              );
            })}
          </DropdownMenuContent>
        </DropdownMenu>
      ) : null}
    </nav>
  );
}
