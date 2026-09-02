"use client";

import type { EntryListItem } from "@/lib/atprotoClient";
import { useWireEdition } from "@/hooks/useWireEdition";
import { Skeleton } from "@/components/ui/skeleton";
import { WireNewsEditionLayout } from "./WireNewsEditionLayout";
import { shouldShowEditorialFeedLoading } from "./editorialFeedLoading";

export function WireNewsExperience({
  onSelect,
}: {
  onSelect: (entryId: string, entry?: EntryListItem) => void;
}) {
  const edition = useWireEdition({
    enabled: true,
    refreshCachedOnMount: true,
  });
  const pages = edition.data?.pages ?? [];
  const storyCount = pages.reduce((count, page) => count + page.stories.length, 0);

  if (
    shouldShowEditorialFeedLoading(
      storyCount,
      edition.isLoading,
      edition.catalog.isLoading,
      edition.isRefreshingFirstPage,
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
          {edition.viewerModerationError
            ? "Your moderation settings could not be applied to The Wire. Retry to load The Wire safely."
            : edition.error instanceof Error
              ? edition.error.message
              : "The Wire edition could not load."}
        </p>
        <button
          type="button"
          className="text-primary underline-offset-4 hover:underline"
          onClick={() => void edition.retryTheWire()}
        >
          Retry
        </button>
      </div>
    );
  }

  const firstPage = pages[0];
  if (!firstPage || firstPage.stories.length === 0) {
    return (
      <div className="flex h-full items-center justify-center p-8 text-center text-sm text-muted-foreground">
        No stories are available on The Wire right now.
      </div>
    );
  }

  return (
    <WireNewsEditionLayout
      pages={pages}
      continuedStories={edition.moreStories}
      hasNextPage={edition.hasNextPage}
      isFetchingNextPage={edition.isFetchingNextPage}
      isLoadMoreError={edition.isFetchNextPageError}
      onLoadMore={edition.fetchNextPage}
      onSelect={onSelect}
    />
  );
}

export default WireNewsExperience;
