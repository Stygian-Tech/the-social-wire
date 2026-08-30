import type { EntryListItem } from "@/lib/atprotoClient";
import { WireStoryCard } from "./WireStoryCard";

export function WireTopStories({
  stories,
  onSelect,
  editionLabel = "The Wire Edition",
}: {
  stories: EntryListItem[];
  onSelect: (entryId: string, entry?: EntryListItem) => void;
  editionLabel?: string;
}) {
  if (stories.length === 0) return null;
  const [lead, ...supporting] = stories;
  return (
    <section aria-labelledby="wire-top-stories" className="px-4 pt-4 sm:px-5 sm:pt-5">
      <div className="mb-3">
        <p className="text-[11px] font-bold uppercase tracking-[0.14em] text-[var(--purple-foreground)]">
          {editionLabel}
        </p>
        <h2 id="wire-top-stories" className="text-xl font-bold text-foreground">
          Top Stories
        </h2>
      </div>
      <div
        data-wire-top-stories-grid
        className="grid items-stretch gap-3 lg:grid-cols-[minmax(0,1.15fr)_minmax(21rem,1fr)]"
      >
        {lead ? (
          <WireStoryCard
            story={lead}
            variant="lead"
            onSelect={onSelect}
          />
        ) : null}
        {supporting.length > 0 ? (
          <div className="grid gap-3 lg:grid-rows-3">
            {supporting.slice(0, 3).map((story) => (
              <WireStoryCard
                key={story.entryId}
                story={story}
                variant="supporting"
                onSelect={onSelect}
              />
            ))}
          </div>
        ) : null}
      </div>
    </section>
  );
}
