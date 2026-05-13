"use client";

import { useMemo, useRef } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { Skeleton } from "@/components/ui/skeleton";
import { EntryRow } from "./EntryRow";
import { useEntries } from "@/hooks/useEntries";
import {
  sortEntryListItemsNewestFirst,
  type EntryListItem,
} from "@/lib/atprotoClient";

interface EntryListProps {
  pubId: string;
  selectedEntryId: string | null;
  onSelectEntry: (entryId: string) => void;
  isEntryRead: (entryId: string) => boolean;
  readIndicatorsEnabled: boolean;
}

export function EntryList({
  pubId,
  selectedEntryId,
  onSelectEntry,
  isEntryRead,
  readIndicatorsEnabled,
}: EntryListProps) {
  const { data, isLoading, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useEntries(pubId);

  const allEntries: EntryListItem[] = useMemo(() => {
    const flat = data?.pages.flatMap((p) => p.entries) ?? [];
    return sortEntryListItemsNewestFirst(flat);
  }, [data?.pages]);

  const parentRef = useRef<HTMLDivElement>(null);

  const virtualizer = useVirtualizer({
    count: hasNextPage ? allEntries.length + 1 : allEntries.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 92,
    overscan: 5,
  });

  const items = virtualizer.getVirtualItems();

  if (isLoading && allEntries.length === 0) {
    return (
      <div className="space-y-2 p-4">
        {Array.from({ length: 6 }).map((_, i) => (
          <Skeleton key={i} className="h-[5.75rem] w-full rounded-md" />
        ))}
      </div>
    );
  }

  if (allEntries.length === 0) {
    return (
      <div className="flex h-full items-center justify-center text-sm text-muted-foreground p-8 text-center">
        No entries found for this publication.
      </div>
    );
  }

  return (
    <div ref={parentRef} className="h-full overflow-y-auto overscroll-y-contain">
      <div
        style={{ height: virtualizer.getTotalSize() }}
        className="relative w-full"
      >
        {items.map((virtualItem) => {
          const isLoaderRow = virtualItem.index === allEntries.length;

          if (isLoaderRow) {
            // Sentinel row: trigger next page load when visible
            if (hasNextPage && !isFetchingNextPage) {
              fetchNextPage();
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
                className="flex items-center justify-center p-4"
              >
                <Skeleton className="h-10 w-full rounded-md" />
              </div>
            );
          }

          const entry = allEntries[virtualItem.index];
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
            >
              <EntryRow
                entry={entry}
                isSelected={selectedEntryId === entry.entryId}
                onSelect={onSelectEntry}
                isRead={isEntryRead(entry.entryId)}
                readIndicatorsEnabled={readIndicatorsEnabled}
              />
            </div>
          );
        })}
      </div>
    </div>
  );
}
