"use client";

import { useMemo } from "react";

import type { EntryListItem } from "@/lib/atprotoClient";
import { useCircleEdition } from "@/hooks/useCircleFeed";
import type { CircleEditionPage } from "@/lib/circleFeedClient";
import type { WireEditionPage } from "@/lib/wireEditionClient";
import { Skeleton } from "@/components/ui/skeleton";
import { WireNewsEditionLayout } from "@/components/Wire/WireNewsEditionLayout";
import { shouldShowEditorialFeedLoading } from "@/components/Wire/editorialFeedLoading";
import {
  CircleStoryActionsProvider,
  useCircleStoryActions,
} from "@/components/Circle/CircleStoryActionsContext";

const EMPTY_CIRCLE_PAGES: CircleEditionPage[] = [];

function CircleActionsError() {
  const actions = useCircleStoryActions();
  if (!actions?.errorMessage) return null;
  return (
    <div role="alert" className="shrink-0 px-4 pt-3 text-sm text-destructive">
      {actions.errorMessage}
    </div>
  );
}

function circlePageForWireLayout(page: CircleEditionPage): WireEditionPage {
  return {
    editionVersion: page.editionVersion,
    generationId: page.generationId,
    generatedAt: page.generatedAt,
    language: page.language,
    source: page.source,
    degraded: page.degraded,
    stories: page.stories.map((story) => ({
      itemId: story.storyId,
      canonicalUrl: story.canonicalUrl,
      representativeUri: story.representativeUri,
      title: story.title,
      summary: story.summary,
      publishedAt: story.publishedAt,
      thumbnailUrl: story.thumbnailUrl,
      source: story.source,
      reasons: [],
      provenance: [],
      circleItem: {
        storyId: story.storyId,
        representativeUri: story.representativeUri,
        source: story.source,
        reasons: story.reasons,
        discussionCount: story.discussionCount,
        sharerCount: story.sharerCount,
        sharers: story.sharers,
        publishedAt: story.publishedAt,
      },
    })),
    topStoryIds: page.topStoryIds,
    publicationSpotlights: page.publicationSpotlights,
    storyRails: page.storyRails,
    people: [],
    trendingStoryIds: page.trendingStoryIds,
    moreCursor: page.moreCursor,
  };
}

export function CircleNewsExperience({
  onSelect,
}: {
  onSelect: (entryId: string, entry?: EntryListItem) => void;
}) {
  const edition = useCircleEdition({ enabled: true });
  const pages = edition.data?.pages ?? EMPTY_CIRCLE_PAGES;
  const storyCount = pages.reduce((count, page) => count + page.stories.length, 0);
  const layoutPages = useMemo(
    () => pages.map(circlePageForWireLayout),
    [pages],
  );

  if (
    shouldShowEditorialFeedLoading(
      storyCount,
      edition.isLoading,
      edition.catalog.isLoading,
      edition.isRefetching,
    )
  ) {
    return (
      <div className="grid h-full gap-4 overflow-hidden p-4 sm:grid-cols-2 xl:grid-cols-[minmax(0,1fr)_19rem]">
        <Skeleton className="h-80 rounded-2xl sm:col-span-2 xl:col-span-1" />
        <Skeleton className="hidden h-[32rem] rounded-2xl xl:block" />
        <Skeleton className="h-52 rounded-2xl" />
        <Skeleton className="h-52 rounded-2xl" />
      </div>
    );
  }

  if (edition.isError && pages.length === 0) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-3 p-8 text-center text-sm text-muted-foreground">
        <p>
          {edition.error instanceof Error
            ? edition.error.message
            : "Your Circle could not load."}
        </p>
        <button
          type="button"
          className="text-primary underline-offset-4 hover:underline"
          onClick={() => void edition.refetch()}
        >
          Retry
        </button>
      </div>
    );
  }

  if (!pages[0] || pages[0].stories.length === 0) {
    return (
      <div className="flex h-full items-center justify-center p-8 text-center text-sm text-muted-foreground">
        No stories have reached Your Circle yet.
      </div>
    );
  }

  const stale = pages[0].degraded || pages[0].source === "stale_generation";

  return (
    <CircleStoryActionsProvider refresh={() => edition.refetch()}>
      <div className="flex h-full min-h-0 flex-col">
        {stale ? (
          <div
            role="status"
            className="shrink-0 border-b border-amber-500/25 bg-amber-500/10 px-4 py-2 text-xs text-foreground"
          >
            Your Circle is showing limited network coverage while it refreshes.
          </div>
        ) : null}
        <CircleActionsError />
        <div className="min-h-0 flex-1">
          <WireNewsEditionLayout
            pages={layoutPages}
            continuedStories={[]}
            hasNextPage={edition.hasNextPage}
            isFetchingNextPage={edition.isFetchingNextPage}
            isLoadMoreError={edition.isFetchNextPageError}
            onLoadMore={edition.fetchNextPage}
            onSelect={onSelect}
            editionLabel="Your Circle"
          />
        </div>
      </div>
    </CircleStoryActionsProvider>
  );
}

export default CircleNewsExperience;
