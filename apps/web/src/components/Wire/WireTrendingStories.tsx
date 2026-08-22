import type { EntryListItem } from "@/lib/atprotoClient";
import { WireStoryCard } from "./WireStoryCard";

export function WireTrendingStories({
  stories,
  onSelect,
}: {
  stories: EntryListItem[];
  onSelect: (entryId: string, entry?: EntryListItem) => void;
}) {
  if (stories.length === 0) return null;
  return (
    <aside
      aria-labelledby="wire-trending-stories"
      tabIndex={0}
      className="mx-4 mt-5 self-start rounded-2xl border border-border/70 bg-muted/20 p-3.5 outline-none sm:mx-5 xl:sticky xl:top-4 xl:mx-0 xl:max-h-[calc(100svh-var(--environment-banner-height,0px)-5rem)] xl:overflow-y-auto xl:overscroll-contain xl:[scrollbar-gutter:stable] xl:focus-visible:ring-2 xl:focus-visible:ring-ring dark:border-border/55"
    >
      <p className="text-[11px] font-bold uppercase tracking-[0.14em] text-[var(--purple-foreground)]">
        What Matters Now
      </p>
      <h2 id="wire-trending-stories" className="mb-3 text-lg font-bold text-foreground">
        Trending Stories
      </h2>
      <div className="grid gap-2">
        {stories.slice(0, 10).map((story, index) => (
          <WireStoryCard
            key={story.entryId}
            story={story}
            variant="trending"
            rank={index + 1}
            onSelect={onSelect}
          />
        ))}
      </div>
    </aside>
  );
}
