"use client";

import { floatingSidebarClassName } from "@/components/shared/floatingSidebarStyles";
import { useViewportSidebar } from "@/hooks/useViewportSidebar";
import type { EntryListItem } from "@/lib/atprotoClient";
import { WireStoryCard } from "./WireStoryCard";

export function WireTrendingStories({
  stories,
  onSelect,
}: {
  stories: EntryListItem[];
  onSelect: (entryId: string, entry?: EntryListItem) => void;
}) {
  const sidebar = useViewportSidebar("[data-slot=sidebar-wrapper]", 1280, stories.length > 0);
  if (stories.length === 0) return null;
  return (
    <aside
      ref={sidebar}
      aria-labelledby="wire-trending-stories"
      tabIndex={0}
      className={`${floatingSidebarClassName} mx-4 mt-4 outline-none xl:fixed xl:right-4 xl:top-[calc(var(--environment-banner-height,0px)+1rem)] xl:mx-0 xl:mt-0 xl:w-[19rem] xl:max-h-[calc(100svh-var(--environment-banner-height,0px)-2rem)] xl:overflow-y-auto xl:overscroll-contain xl:[scrollbar-gutter:stable] xl:focus-visible:ring-2 xl:focus-visible:ring-ring`}
    >
      <p className="text-[11px] font-bold uppercase tracking-[0.14em] text-[var(--purple-foreground)]">
        What Matters Now
      </p>
      <h2 id="wire-trending-stories" className="mb-2 text-base font-bold text-foreground">
        Trending Stories
      </h2>
      <div
        data-wire-trending-list
        className="grid divide-y divide-border/60 dark:divide-border/45"
      >
        {stories.slice(0, 10).map((story) => (
          <WireStoryCard
            key={story.entryId}
            story={story}
            variant="trending"
            onSelect={onSelect}
          />
        ))}
      </div>
    </aside>
  );
}
