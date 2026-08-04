"use client";

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
} from "react";
import { Skeleton } from "@/components/ui/skeleton";
import {
  useAggregateFeedEntries,
  useEntries,
} from "@/hooks/useEntries";
import { useProactiveFeedRefresh } from "@/hooks/useProactiveFeedRefresh";
import {
  sortEntryListItemsNewestFirst,
  type EntryListItem,
} from "@/lib/atprotoClient";
import { dedupeEntryListItems } from "@/lib/rssFeedCore";
import {
  filterEntriesForArticleFilter,
  shouldShowNoUnreadEntriesState,
  type ArticleListFilter,
} from "@/lib/entryArticleFilter";
import { EntryListVirtualPane } from "./EntryListVirtualPane";
import type { AggregateAppViewFeed } from "@/lib/thinAppViewClient";
import {
  mergeAggregateEntryPagesCached,
} from "@/lib/aggregateEntryPages";
import {
  markSubscribedPaginationTriggered,
  markSubscribedRowsRendered,
} from "@/lib/subscribedFeedPerf";
import { useSidebarProjection } from "@/contexts/PublicationSidebarContext";
import { CursorSingleFlight } from "@/lib/cursorSingleFlight";

export type { ArticleListFilter };

interface EntryListProps {
  pubId?: string;
  aggregateFeed?: AggregateAppViewFeed;
  selectedEntryId: string | null;
  onSelectEntry: (entryId: string, entry?: EntryListItem) => void;
  isEntryRead: (entryId: string) => boolean;
  readIndicatorsEnabled: boolean;
  /** When false, read/unread visuals are suppressed without changing persisted state. */
  articleFilter: ArticleListFilter;
  markEntryRead: (entryId: string) => void;
  markEntryUnread: (entryId: string) => void;
}

function virtualFeedIdentity(
  aggregateFeed: AggregateAppViewFeed | undefined,
  pubId: string | undefined,
): string {
  return pubId ?? `${aggregateFeed?.kind}:${aggregateFeed?.id ?? ""}`;
}

export function EntryList({
  pubId,
  aggregateFeed,
  selectedEntryId,
  onSelectEntry,
  isEntryRead,
  readIndicatorsEnabled,
  articleFilter,
  markEntryRead,
  markEntryUnread,
}: EntryListProps) {
  const effectiveFilter: ArticleListFilter = useMemo(() => {
    if (!readIndicatorsEnabled) return "all";
    return articleFilter;
  }, [readIndicatorsEnabled, articleFilter]);

  // AppView performs the bounded unread scan. The local read-state overlay still
  // suppresses rows immediately while read-mark write-through catches up.
  const {
    data,
    isLoading,
    isError,
    error,
    refetch,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
    isFetchNextPageError,
    scopePending,
  } = useEntries(pubId ?? null, effectiveFilter);
  const aggregateQuery = useAggregateFeedEntries(
    aggregateFeed ?? null,
    effectiveFilter,
  );
  const activeData = aggregateFeed ? aggregateQuery.data : data;
  const activeLoading = aggregateFeed ? aggregateQuery.isLoading : isLoading;
  const activeIsError = aggregateFeed ? aggregateQuery.isError : isError;
  const activeError = aggregateFeed ? aggregateQuery.error : error;
  const activeRefetch = aggregateFeed ? aggregateQuery.refetch : refetch;
  const activeFetchNextPage = aggregateFeed
    ? aggregateQuery.fetchNextPage
    : fetchNextPage;
  const activeHasNextPage = aggregateFeed
    ? aggregateQuery.hasNextPage
    : hasNextPage;
  const activeIsFetchingNextPage = aggregateFeed
    ? aggregateQuery.isFetchingNextPage
    : isFetchingNextPage;
  const activeIsFetchNextPageError = aggregateFeed
    ? aggregateQuery.isFetchNextPageError
    : isFetchNextPageError;
  const { allPublicationRows } = useSidebarProjection();

  const publicationById = useMemo(() => {
    const map = new Map<
      string,
      { name: string; faviconUrl?: string }
    >();
    for (const publication of allPublicationRows) {
      map.set(publication.publicationId, {
        name: publication.title,
        faviconUrl: publication.iconUrl ?? publication.avatarUrl ?? undefined,
      });
    }
    return map;
  }, [allPublicationRows]);

  useProactiveFeedRefresh(
    pubId ?? null,
    "all",
    !aggregateFeed &&
      effectiveFilter === "all" &&
      !isLoading &&
      !scopePending &&
      (data?.pages.length ?? 0) > 0
  );

  const aggregateAccumulator = useMemo(() => {
    if (!aggregateFeed) return undefined;
    return mergeAggregateEntryPagesCached(aggregateQuery.data?.pages ?? []);
  }, [aggregateFeed, aggregateQuery.data?.pages]);
  const aggregateEntries = aggregateAccumulator?.entries ?? [];

  const publicationEntries: EntryListItem[] = useMemo(() => {
    const flat = dedupeEntryListItems(
      data?.pages.flatMap((p) => p.entries) ?? [],
    );
    return sortEntryListItemsNewestFirst(flat);
  }, [data?.pages]);

  const allEntries = aggregateFeed ? aggregateEntries : publicationEntries;

  const previousAggregateEntryCountRef = useRef({
    feedKey: virtualFeedIdentity(aggregateFeed, pubId),
    count: 0,
  });
  useLayoutEffect(() => {
    if (aggregateFeed?.kind !== "subscribed") return;
    const feedKey = virtualFeedIdentity(aggregateFeed, pubId);
    const previous =
      previousAggregateEntryCountRef.current.feedKey === feedKey
        ? previousAggregateEntryCountRef.current.count
        : 0;
    const appendedRows =
      aggregateEntries.length - previous;
    previousAggregateEntryCountRef.current = {
      feedKey,
      count: aggregateEntries.length,
    };
    markSubscribedRowsRendered({
      appendedRows,
      mergeDurationMs: aggregateAccumulator?.mergeDurationMs ?? 0,
    });
  }, [aggregateAccumulator, aggregateFeed, aggregateEntries.length, pubId]);

  const visibleEntries: EntryListItem[] = useMemo(() => {
    const authoritativeReadIds = new Set(
      allEntries.filter((entry) => entry.isRead).map((entry) => entry.entryId)
    );
    return filterEntriesForArticleFilter(
      allEntries,
      effectiveFilter,
      (entryId) => isEntryRead(entryId) || authoritativeReadIds.has(entryId)
    );
  }, [allEntries, effectiveFilter, isEntryRead]);

  /** Remount only when the user changes publication/filter; data churn must not reset scroll. */
  const virtualPaneKey = useMemo(() => {
    return `${virtualFeedIdentity(aggregateFeed, pubId)}:${effectiveFilter}`;
  }, [aggregateFeed, pubId, effectiveFilter]);

  const nextPageRequestRef = useRef(new CursorSingleFlight());

  useEffect(() => {
    nextPageRequestRef.current.reset();
  }, [virtualPaneKey]);

  const fetchNextPageOnce = useCallback((): Promise<unknown> => {
    const cursor =
      activeData?.pages[activeData.pages.length - 1]?.cursor ?? "__first_page__";
    if (!activeHasNextPage || activeIsFetchingNextPage) {
      return Promise.resolve();
    }

    return nextPageRequestRef.current.run({
      feedKey: virtualPaneKey,
      cursor,
      request: () => {
        if (aggregateFeed?.kind === "subscribed") {
          markSubscribedPaginationTriggered();
        }
        return activeFetchNextPage();
      },
    });
  }, [
    activeData,
    activeFetchNextPage,
    activeHasNextPage,
    activeIsFetchingNextPage,
    aggregateFeed?.kind,
    virtualPaneKey,
  ]);

  if (
    (activeLoading || (!aggregateFeed && scopePending)) &&
    allEntries.length === 0
  ) {
    return (
      <div className="space-y-1.5 p-2">
        {Array.from({ length: 6 }).map((_, i) => (
          <Skeleton key={i} className="h-36 w-full rounded-lg" />
        ))}
      </div>
    );
  }

  if (activeIsError && allEntries.length === 0) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-3 p-8 text-center text-sm text-muted-foreground">
        <p>
          {activeError instanceof Error
            ? activeError.message
            : "Could not load entries."}
        </p>
        <button
          type="button"
          className="text-primary underline-offset-4 hover:underline"
          onClick={() => void activeRefetch()}
        >
          Retry
        </button>
      </div>
    );
  }

  if (allEntries.length === 0) {
    return (
      <div className="flex h-full items-center justify-center p-8 text-center text-sm text-muted-foreground">
        {effectiveFilter === "unread"
          ? "No unread entries for this publication."
          : "No entries found for this publication."}
      </div>
    );
  }

  if (
    shouldShowNoUnreadEntriesState({
      effectiveFilter,
      visibleEntryCount: visibleEntries.length,
      hasNextPage: activeHasNextPage,
      isFetchingNextPage: activeIsFetchingNextPage,
    })
  ) {
    return (
      <div className="flex h-full items-center justify-center p-8 text-center text-sm text-muted-foreground">
        No unread entries for this publication.
      </div>
    );
  }

  return (
    <EntryListVirtualPane
      key={virtualPaneKey}
      visibleEntries={visibleEntries}
      selectedEntryId={selectedEntryId}
      onSelectEntry={onSelectEntry}
      isEntryRead={isEntryRead}
      readIndicatorsEnabled={readIndicatorsEnabled}
      hasNextPage={activeHasNextPage}
      isFetchingNextPage={activeIsFetchingNextPage}
      isFetchNextPageError={activeIsFetchNextPageError}
      fetchNextPage={fetchNextPageOnce}
      scrollStateKey={virtualPaneKey}
      publicationById={publicationById}
      markEntryRead={markEntryRead}
      markEntryUnread={markEntryUnread}
    />
  );
}
