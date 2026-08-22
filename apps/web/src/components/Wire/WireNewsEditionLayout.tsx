"use client";

import { useMemo } from "react";

import { Button } from "@/components/ui/button";
import type { EntryListItem } from "@/lib/atprotoClient";
import type { WireEditionPage } from "@/lib/wireEditionClient";
import { wireItemToEntryListItem } from "@/lib/wireFeedClient";
import { WirePublicationSpotlights } from "./WirePublicationSpotlights";
import { WireStoryRail } from "./WireStoryRail";
import { WireTalkedAboutPeople } from "./WireTalkedAboutPeople";
import { WireTopStories } from "./WireTopStories";
import { WireTrendingStories } from "./WireTrendingStories";

export function WireNewsEditionLayout({
  pages,
  continuedStories,
  hasNextPage,
  isFetchingNextPage,
  isLoadMoreError,
  onLoadMore,
  onSelect,
}: {
  pages: WireEditionPage[];
  continuedStories: EntryListItem[];
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
  isLoadMoreError: boolean;
  onLoadMore: () => Promise<unknown>;
  onSelect: (entryId: string, entry?: EntryListItem) => void;
}) {
  const edition = pages[0];
  const model = useMemo(() => {
    if (!edition) return null;
    const storiesById = new Map<string, EntryListItem>();
    const orderedStories: EntryListItem[] = [];
    for (const page of pages) {
      if (page.generationId !== edition.generationId) continue;
      for (const item of page.stories) {
        if (storiesById.has(item.itemId)) continue;
        const story = wireItemToEntryListItem(item, page.generatedAt);
        storiesById.set(item.itemId, story);
        orderedStories.push(story);
      }
    }
    const storiesForIds = (ids: readonly string[]) =>
      ids
        .map((id) => storiesById.get(id))
        .filter((story): story is EntryListItem => Boolean(story));
    const topStories = storiesForIds(edition.topStoryIds);
    const effectiveTopStories =
      topStories.length > 0 ? topStories.slice(0, 4) : orderedStories.slice(0, 4);
    const trendingStories = storiesForIds(edition.trendingStoryIds);
    const reservedIds = new Set<string>([
      ...edition.topStoryIds,
      ...edition.trendingStoryIds,
      ...edition.publicationSpotlights.flatMap((spotlight) => spotlight.storyIds),
      ...edition.storyRails.flatMap((rail) => rail.storyIds),
    ]);
    const moreStories = orderedStories.filter((story) => {
      const itemId = story.wireItem?.itemId;
      return !itemId || !reservedIds.has(itemId);
    });
    const seenMore = new Set(
      moreStories.map((story) => story.wireItem?.itemId ?? story.entryId),
    );
    for (const story of continuedStories) {
      const id = story.wireItem?.itemId ?? story.entryId;
      if (seenMore.add(id)) moreStories.push(story);
    }
    return {
      storiesById,
      effectiveTopStories,
      trendingStories,
      moreStories,
    };
  }, [continuedStories, edition, pages]);

  if (!edition || !model) return null;
  return (
    <div
      data-wire-edition-version={edition.editionVersion}
      data-wire-generation={edition.generationId}
      className="h-full overflow-y-auto overscroll-y-contain bg-background"
    >
      <div className="grid min-w-0 xl:grid-cols-[minmax(0,1fr)_19rem] xl:gap-x-5">
        <div className="min-w-0 xl:col-start-1 xl:row-start-1">
          <WireTopStories stories={model.effectiveTopStories} onSelect={onSelect} />
        </div>
        <div className="min-w-0 xl:col-start-2 xl:row-span-2 xl:row-start-1">
          <WireTrendingStories stories={model.trendingStories} onSelect={onSelect} />
        </div>
        <div className="min-w-0 space-y-7 pb-8 pt-7 xl:col-start-1 xl:row-start-2">
          <WirePublicationSpotlights
            spotlights={edition.publicationSpotlights}
            storiesById={model.storiesById}
            onSelect={onSelect}
          />
          <WireTalkedAboutPeople people={edition.people} />
          {edition.storyRails.map((rail) => (
            <WireStoryRail
              key={rail.id}
              id={rail.id}
              title={rail.title}
              stories={rail.storyIds
                .map((id) => model.storiesById.get(id))
                .filter((story): story is EntryListItem => Boolean(story))}
              onSelect={onSelect}
            />
          ))}
          <WireStoryRail
            id="more-stories"
            eyebrow="Keep Reading"
            title="More Stories"
            stories={model.moreStories}
            onSelect={onSelect}
            onNearEnd={
              hasNextPage && !isFetchingNextPage
                ? () => void onLoadMore()
                : undefined
            }
          />
          {hasNextPage ? (
            <div className="flex justify-center px-4 sm:px-5">
              <Button
                type="button"
                variant="outline"
                disabled={isFetchingNextPage}
                onClick={() => void onLoadMore()}
              >
                {isFetchingNextPage
                  ? "Loading More…"
                  : isLoadMoreError
                    ? "Could Not Load More — Retry"
                    : "Load More Stories"}
              </Button>
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}
