"use client";

import { useEffect, useMemo, useRef } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { Skeleton } from "@/components/ui/skeleton";
import { EntryRow } from "./EntryRow";
import { useEntries } from "@/hooks/useEntries";
import {
  sortEntryListItemsNewestFirst,
  type EntryListItem,
} from "@/lib/atprotoClient";
import {
  filterEntriesForArticleFilter,
  type ArticleListFilter,
} from "@/lib/entryArticleFilter";

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

type VirtualPaneProps = {
  visibleEntries: EntryListItem[];
  selectedEntryId: string | null;
  onSelectEntry: (entryId: string) => void;
  isEntryRead: (entryId: string) => boolean;
  readIndicatorsEnabled: boolean;
  hasNextPage: boolean;
  isFetchingNextPage: boolean;
  fetchNextPage: () => void;
  markEntryRead: (entryId: string) => void;
  markEntryUnread: (entryId: string) => void;
};

/**
 * Isolated virtual list so we can remount it when the filter changes and reset
 * TanStack Virtual measurements (avoids overlapping rows / stray borders).
 */
function EntryListVirtualPane({
  visibleEntries,
  selectedEntryId,
  onSelectEntry,
  isEntryRead,
  readIndicatorsEnabled,
  hasNextPage,
  isFetchingNextPage,
  fetchNextPage,
  markEntryRead,
  markEntryUnread,
}: VirtualPaneProps) {
  const parentRef = useRef<HTMLDivElement>(null);

  const virtualCount =
    hasNextPage ? visibleEntries.length + 1 : visibleEntries.length;

  // eslint-disable-next-line react-hooks/incompatible-library -- TanStack Virtual's internal store is not React-memoizable
  const virtualizer = useVirtualizer({
    count: virtualCount,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 112,
    overscan: 5,
  });

  const items = virtualizer.getVirtualItems();

  return (
    <div ref={parentRef} className="h-full overflow-y-auto overscroll-y-contain">
      <div
        style={{ height: virtualizer.getTotalSize() }}
        className="relative w-full"
      >
        {items.map((virtualItem) => {
          const isLoaderRow = virtualItem.index === visibleEntries.length;

          if (isLoaderRow) {
            if (hasNextPage && !isFetchingNextPage) {
              void fetchNextPage();
            }
            return (
              <div
                key="loader"
                style={{
                  position: "absolute",
                  top: 0,
                  left: 0,
                  width: "100%",
                  transform: `translateY(${virtualItem.start}px)`,
                  height: virtualItem.size,
                }}
                className="flex items-center justify-center border-b border-transparent p-4"
              >
                <Skeleton className="h-10 w-full rounded-md" />
              </div>
            );
          }

          const entry = visibleEntries[virtualItem.index];
          return (
            <div
              key={entry.entryId}
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                width: "100%",
                transform: `translateY(${virtualItem.start}px)`,
              }}
              ref={virtualizer.measureElement}
              data-index={virtualItem.index}
              data-entry-id={entry.entryId}
            >
              <EntryRow
                entry={entry}
                isSelected={selectedEntryId === entry.entryId}
                onSelect={onSelectEntry}
                isRead={isEntryRead(entry.entryId)}
                readIndicatorsEnabled={readIndicatorsEnabled}
                onMarkEntryRead={markEntryRead}
                onMarkEntryUnread={markEntryUnread}
              />
            </div>
          );
        })}
      </div>
    </div>
  );
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

  const { data, isLoading, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useEntries(pubId, effectiveFilter);

  const allEntries: EntryListItem[] = useMemo(() => {
    const flat = data?.pages.flatMap((p) => p.entries) ?? [];
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

  if (isLoading && allEntries.length === 0) {
    return (
      <div className="space-y-2 p-4">
        {Array.from({ length: 6 }).map((_, i) => (
          <Skeleton key={i} className="h-28 w-full rounded-md" />
        ))}
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
          <Skeleton key={i} className="h-28 w-full rounded-md" />
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
      fetchNextPage={fetchNextPage}
      markEntryRead={markEntryRead}
      markEntryUnread={markEntryUnread}
    />
  );
}
