"use client";

import { useEffect, useRef } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import { EntryRow } from "./EntryRow";
import type { EntryListVirtualPaneProps } from "./EntryListVirtualPane.types";

/**
 * Isolated virtual list so we can remount it when the filter changes and reset
 * TanStack Virtual measurements (avoids overlapping rows / stray borders).
 */
export function EntryListVirtualPane({
  visibleEntries,
  selectedEntryId,
  onSelectEntry,
  isEntryRead,
  readIndicatorsEnabled,
  hasNextPage,
  isFetchingNextPage,
  isFetchNextPageError,
  fetchNextPage,
  markEntryRead,
  markEntryUnread,
}: EntryListVirtualPaneProps) {
  const parentRef = useRef<HTMLDivElement>(null);
  const loaderRef = useRef<HTMLDivElement>(null);

  const virtualCount =
    hasNextPage ? visibleEntries.length + 1 : visibleEntries.length;

  useEffect(() => {
    if (!hasNextPage || isFetchingNextPage) return;
    const loader = loaderRef.current;
    const root = parentRef.current;
    if (!loader || !root) return;

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          void fetchNextPage();
        }
      },
      { root, rootMargin: "240px", threshold: 0 }
    );

    observer.observe(loader);
    return () => observer.disconnect();
  }, [
    hasNextPage,
    isFetchingNextPage,
    fetchNextPage,
    visibleEntries.length,
  ]);

  // eslint-disable-next-line react-hooks/incompatible-library -- TanStack Virtual's internal store is not React-memoizable
  const virtualizer = useVirtualizer({
    count: virtualCount,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 112,
    overscan: 5,
  });

  const items = virtualizer.getVirtualItems();

  return (
    <div
      ref={parentRef}
      data-entry-list-scroll
      className="h-full overflow-y-auto overscroll-y-contain"
    >
      <div
        style={{ height: virtualizer.getTotalSize() }}
        className="relative w-full"
      >
        {items.map((virtualItem) => {
          const isLoaderRow = virtualItem.index === visibleEntries.length;

          if (isLoaderRow) {
            return (
              <div
                key="loader"
                ref={loaderRef}
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
                {isFetchNextPageError ? (
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() => void fetchNextPage()}
                  >
                    Could Not Load More — Retry
                  </Button>
                ) : (
                  <Skeleton className="h-10 w-full rounded-md" />
                )}
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
