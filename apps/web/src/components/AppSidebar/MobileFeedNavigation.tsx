"use client";

import { Archive, Bookmark, Newspaper, Rss, Users } from "lucide-react";

import type { ReaderNavigationFeed } from "@/lib/feedPreferences";
import { cn } from "@/lib/utils";
import { WireAlphaBadge } from "@/components/Wire/WireAlphaBadge";

const FEED_ITEMS = [
  { feed: "wire", label: "The Wire", icon: Rss },
  { feed: "readLater", label: "Saved", icon: Bookmark },
  { feed: "archive", label: "Archive", icon: Archive },
  { feed: "subscribed", label: "Subscribed", icon: Newspaper },
  { feed: "following", label: "Following", icon: Users },
] as const;

export function MobileFeedNavigation({
  currentFeed,
  visibleFeeds,
  onSelect,
}: {
  currentFeed: ReaderNavigationFeed | null;
  visibleFeeds: Set<ReaderNavigationFeed>;
  onSelect: (feed: ReaderNavigationFeed) => void;
}) {
  const items = FEED_ITEMS.filter(({ feed }) => visibleFeeds.has(feed));
  if (items.length === 0) return null;

  return (
    <nav
      aria-label="Feed Navigation"
      className="fixed inset-x-0 bottom-0 z-40 grid border-t border-border/70 bg-background/95 px-2 pb-[env(safe-area-inset-bottom)] backdrop-blur-md md:hidden"
      style={{ gridTemplateColumns: `repeat(${items.length}, minmax(0, 1fr))` }}
    >
      {items.map(({ feed, label, icon: Icon }) => {
        const active = currentFeed === feed;
        return (
          <button
            key={feed}
            type="button"
            aria-label={feed === "wire" ? "The Wire, Alpha" : label}
            aria-current={active ? "page" : undefined}
            className={cn(
              "flex min-h-16 min-w-0 flex-col items-center justify-center gap-1 px-1 text-[11px] font-medium text-muted-foreground transition-colors",
              "hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring",
              active && "text-[var(--purple-foreground)]",
            )}
            onClick={() => onSelect(feed)}
          >
            <Icon className="size-5" aria-hidden="true" />
            <span className="flex min-w-0 items-center gap-1">
              <span className="truncate">{label}</span>
              {feed === "wire" ? (
                <WireAlphaBadge className="px-1 py-px text-[7px]" />
              ) : null}
            </span>
          </button>
        );
      })}
    </nav>
  );
}
