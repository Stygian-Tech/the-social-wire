import { PublicationChip } from "@/components/shared/PublicationChip";
import type { EntryListItem } from "@/lib/atprotoClient";
import type { WirePublicationSpotlight } from "@/lib/wireEditionClient";
import { WireHorizontalRail } from "./WireHorizontalRail";
import { WireStoryCard } from "./WireStoryCard";

type SpotlightPublicationPresentation = {
  name: string;
  domain: string;
  homepageUrl?: string;
  iconUrl?: string;
};

function normalizedLocator(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\//, "")
    .replace(/^www\./, "")
    .replace(/\/$/, "");
}

function isWeakPublicationName(name: string, domain: string): boolean {
  const trimmed = name.trim();
  if (
    !trimmed ||
    trimmed.toLowerCase() === "publication" ||
    /^at:\/\//i.test(trimmed) ||
    /^https?:\/\//i.test(trimmed)
  ) {
    return true;
  }
  return Boolean(domain.trim()) && normalizedLocator(trimmed) === normalizedLocator(domain);
}

export function effectiveSpotlightPublication(
  spotlight: WirePublicationSpotlight,
  stories: readonly EntryListItem[],
): SpotlightPublicationPresentation {
  const publication = spotlight.publication;
  const storySources = stories.flatMap((story) =>
    story.wireItem?.source ? [story.wireItem.source] : [],
  );
  const domain =
    publication.domain.trim() ||
    storySources.find((source) => source.domain.trim())?.domain.trim() ||
    "";
  const resolvedStoryName = storySources.find(
    (source) => !isWeakPublicationName(source.name, source.domain),
  )?.name.trim();
  const name = !isWeakPublicationName(publication.name, domain)
    ? publication.name.trim()
    : resolvedStoryName || domain || "Publication";
  const homepageUrl =
    publication.homepageUrl?.trim() ||
    storySources.find((source) => source.homepageUrl?.trim())?.homepageUrl?.trim();
  const iconUrl =
    publication.iconUrl?.trim() ||
    storySources.find((source) => source.iconUrl?.trim())?.iconUrl?.trim();

  return {
    name,
    domain,
    ...(homepageUrl ? { homepageUrl } : {}),
    ...(iconUrl ? { iconUrl } : {}),
  };
}

export function WirePublicationSpotlights({
  spotlights,
  storiesById,
  onSelect,
}: {
  spotlights: WirePublicationSpotlight[];
  storiesById: ReadonlyMap<string, EntryListItem>;
  onSelect: (entryId: string, entry?: EntryListItem) => void;
}) {
  const populated = spotlights
    .map((spotlight) => ({
      spotlight,
      stories: spotlight.storyIds
        .map((id) => storiesById.get(id))
        .filter((story): story is EntryListItem => Boolean(story))
        .slice(0, 3),
    }))
    .filter(({ stories }) => stories.length > 0);
  if (populated.length === 0) return null;

  return (
    <WireHorizontalRail
      id="publication-spotlights"
      eyebrow="From The Newsroom"
      title="Publication Spotlights"
    >
      {populated.map(({ spotlight, stories }) => {
        const publication = effectiveSpotlightPublication(spotlight, stories);
        return (
          <article
            key={spotlight.id}
            data-wire-publication-spotlight={spotlight.id}
            className="w-[min(82vw,25rem)] shrink-0 snap-start rounded-2xl border border-border/70 bg-muted/20 p-3.5 sm:w-[24rem] dark:border-border/55"
          >
            <div className="mb-3 border-b border-border/60 pb-3">
              <PublicationChip
                publication={{
                  name: publication.name,
                  faviconUrl: publication.iconUrl,
                  homepageUrl: publication.homepageUrl,
                }}
                className="border-0 bg-transparent px-0 py-0 text-sm text-foreground"
              />
              {publication.domain && publication.domain !== publication.name ? (
                <p className="mt-1 truncate text-xs text-muted-foreground">
                  {publication.domain}
                </p>
              ) : null}
            </div>
            <div className="grid gap-2">
              {stories.map((story, index) => (
                <WireStoryCard
                  key={story.entryId}
                  story={story}
                  variant={index === 0 ? "standard" : "compact"}
                  onSelect={onSelect}
                />
              ))}
            </div>
          </article>
        );
      })}
    </WireHorizontalRail>
  );
}
