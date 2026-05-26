"use client";

import { useEffect, useMemo } from "react";
import { Skeleton } from "@/components/ui/skeleton";
import { useEntries } from "@/hooks/useEntries";
import { useProactiveFeedRefresh } from "@/hooks/useProactiveFeedRefresh";
import {
  sortEntryListItemsNewestFirst,
  type EntryListItem,
} from "@/lib/atprotoClient";
import { dedupeEntryListItems } from "@/lib/rssFeedCore";
import {
  filterEntriesForArticleFilter,
  type ArticleListFilter,
} from "@/lib/entryArticleFilter";
import { EntryListVirtualPane } from "./EntryListVirtualPane";

export type { ArticleListFilter };

interface EntryListProps {
  pubId: string;
  selectedEntryId: string | null;
  onSelectEntry: (entryId: string) => void;
  isEntryRead: (entryId: string) => boolean;
  readIndicatorsEnabled: boolean;
  /** When false, read/unread visuals are suppressed without changing persisted state. */
  articleFilter: ArticleListFilter;
  markEntryRead: (entryId: string) => void;
  markEntryUnread: (entryId: string) => void;
}

export function EntryList({
  pubId,
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

  // Read/unread is tracked client-side (`ReadRouteContext`). Always fetch the
  // full list from AppView and apply the All/Unread filter locally so tab
  // switches and context-menu marks stay in sync even when read-mark write-through
  // to AppView is still catching up.
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
  } = useEntries(pubId, "all");

  useProactiveFeedRefresh(
    pubId,
    "all",
    !isLoading && !scopePending && (data?.pages.length ?? 0) > 0
  );

  const allEntries: EntryListItem[] = useMemo(() => {
    const flat = dedupeEntryListItems(data?.pages.flatMap((p) => p.entries) ?? []);
    return sortEntryListItemsNewestFirst(flat);
  }, [data?.pages]);

  const visibleEntries: EntryListItem[] = useMemo(() => {
    return filterEntriesForArticleFilter(
      allEntries,
      effectiveFilter,
      isEntryRead
    );
  }, [allEntries, effectiveFilter, isEntryRead]);

  /** Unread: remount when membership changes (mark read removes a row). All: stable per pub + filter only. */
  const virtualPaneKey = useMemo(() => {
    if (effectiveFilter === "unread") {
      return `${pubId}:unread:${visibleEntries.map((e) => e.entryId).join("\x1e")}`;
    }
    return `${pubId}:${effectiveFilter}`;
  }, [pubId, effectiveFilter, visibleEntries]);

  useEffect(() => {
    if (effectiveFilter !== "unread" || !readIndicatorsEnabled) return;
    if (!hasNextPage || isFetchingNextPage) return;
    if (visibleEntries.length > 0) return;
    if (allEntries.length === 0 || isLoading) return;
    void fetchNextPage();
  }, [
    effectiveFilter,
    readIndicatorsEnabled,
    hasNextPage,
    isFetchingNextPage,
    visibleEntries.length,
    allEntries.length,
    isLoading,
    fetchNextPage,
  ]);

  if ((isLoading || scopePending) && allEntries.length === 0) {
    return (
      <div className="space-y-1.5 p-2">
        {Array.from({ length: 6 }).map((_, i) => (
          <Skeleton key={i} className="h-36 w-full rounded-lg" />
        ))}
      </div>
    );
  }

  if (isError && allEntries.length === 0) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-3 p-8 text-center text-sm text-muted-foreground">
        <p>{error instanceof Error ? error.message : "Could not load entries."}</p>
        <button
          type="button"
          className="text-primary underline-offset-4 hover:underline"
          onClick={() => void refetch()}
        >
          Retry
        </button>
      </div>
    );
  }

  if (allEntries.length === 0) {
    return (
      <div className="flex h-full items-center justify-center p-8 text-center text-sm text-muted-foreground">
        No entries found for this publication.
      </div>
    );
  }

  if (
    effectiveFilter === "unread" &&
    visibleEntries.length === 0 &&
    allEntries.length > 0 &&
    (hasNextPage || isFetchingNextPage)
  ) {
    return (
      <div className="space-y-2 p-4">
        {Array.from({ length: 4 }).map((_, i) => (
          <Skeleton key={i} className="h-36 w-full rounded-lg" />
        ))}
      </div>
    );
  }

  if (effectiveFilter === "unread" && visibleEntries.length === 0) {
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
      hasNextPage={hasNextPage}
      isFetchingNextPage={isFetchingNextPage}
      isFetchNextPageError={isFetchNextPageError}
      fetchNextPage={fetchNextPage}
      markEntryRead={markEntryRead}
      markEntryUnread={markEntryUnread}
    />
  );
}
