"use client";

import { useCallback, useEffect, useLayoutEffect, useRef } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { Skeleton } from "@/components/ui/skeleton";
import { Button } from "@/components/ui/button";
import { EntryRow } from "./EntryRow";
import type { EntryListVirtualPaneProps } from "./EntryListVirtualPane.types";
import {
  shouldFillViewportFetch,
  shouldScrollNearEndFetch,
} from "@/lib/entryListPaginationTriggers";

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
  const loaderNodeRef = useRef<HTMLDivElement | null>(null);
  const observerRef = useRef<IntersectionObserver | null>(null);
  const scrollTopRef = useRef(0);
  const fetchNextPageRef = useRef(fetchNextPage);
  fetchNextPageRef.current = fetchNextPage;
  const hasNextPageRef = useRef(hasNextPage);
  hasNextPageRef.current = hasNextPage;
  const isFetchingNextPageRef = useRef(isFetchingNextPage);
  isFetchingNextPageRef.current = isFetchingNextPage;

  const virtualCount =
    hasNextPage ? visibleEntries.length + 1 : visibleEntries.length;

  const disconnectLoaderObserver = useCallback(() => {
    observerRef.current?.disconnect();
    observerRef.current = null;
  }, []);

  const attachLoaderObserver = useCallback(
    (loader: HTMLDivElement) => {
      disconnectLoaderObserver();
      if (!hasNextPage || isFetchingNextPage) return;

      const root = parentRef.current;
      if (!root) return;

      const observer = new IntersectionObserver(
        (entries) => {
          if (entries.some((entry) => entry.isIntersecting)) {
            void fetchNextPageRef.current();
          }
        },
        { root, rootMargin: "240px", threshold: 0 }
      );
      observer.observe(loader);
      observerRef.current = observer;
    },
    [disconnectLoaderObserver, hasNextPage, isFetchingNextPage]
  );

  const loaderRef = useCallback(
    (node: HTMLDivElement | null) => {
      loaderNodeRef.current = node;
      if (!node) {
        disconnectLoaderObserver();
        return;
      }
      attachLoaderObserver(node);
    },
    [attachLoaderObserver, disconnectLoaderObserver]
  );

  useEffect(() => {
    if (!hasNextPage || isFetchingNextPage) {
      disconnectLoaderObserver();
      return;
    }
    const loader = loaderNodeRef.current;
    if (loader) attachLoaderObserver(loader);
  }, [
    attachLoaderObserver,
    disconnectLoaderObserver,
    hasNextPage,
    isFetchingNextPage,
    visibleEntries.length,
  ]);

  useEffect(() => {
    return () => disconnectLoaderObserver();
  }, [disconnectLoaderObserver]);

  useEffect(() => {
    const root = parentRef.current;
    if (!root) return;

    scrollTopRef.current = root.scrollTop;
    const rememberScrollTop = () => {
      scrollTopRef.current = root.scrollTop;
    };
    root.addEventListener("scroll", rememberScrollTop, { passive: true });
    return () => root.removeEventListener("scroll", rememberScrollTop);
  }, []);

  useLayoutEffect(() => {
    const root = parentRef.current;
    if (!root) return;
    root.scrollTop = scrollTopRef.current;
  }, [visibleEntries]);

  useEffect(() => {
    const root = parentRef.current;
    if (!root || !hasNextPage || isFetchingNextPage) return;

    const maybeFetch = () => {
      if (isFetchingNextPageRef.current || !hasNextPageRef.current) return;
      const rootEl = parentRef.current;
      if (!rootEl) return;
      if (
        shouldFillViewportFetch({
          scrollHeight: rootEl.scrollHeight,
          clientHeight: rootEl.clientHeight,
          hasNextPage: hasNextPageRef.current,
          isFetchingNextPage: isFetchingNextPageRef.current,
        }) ||
        shouldScrollNearEndFetch({
          scrollTop: rootEl.scrollTop,
          scrollHeight: rootEl.scrollHeight,
          clientHeight: rootEl.clientHeight,
        })
      ) {
        void fetchNextPageRef.current();
      }
    };

    maybeFetch();
    root.addEventListener("scroll", maybeFetch, { passive: true });
    return () => root.removeEventListener("scroll", maybeFetch);
  }, [hasNextPage, isFetchingNextPage, visibleEntries.length]);

  // eslint-disable-next-line react-hooks/incompatible-library -- TanStack Virtual's internal store is not React-memoizable
  const virtualizer = useVirtualizer({
    count: virtualCount,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 130,
    initialRect: { width: 0, height: 800 },
    gap: 8,
    overscan: 5,
  });

  const items = virtualizer.getVirtualItems();
  const firstItem = items[0];
  const lastItem = items.at(-1);
  const paddingTop = firstItem?.start ?? 0;
  const paddingBottom = lastItem
    ? Math.max(0, virtualizer.getTotalSize() - lastItem.end)
    : 0;

  return (
    <div
      ref={parentRef}
      data-entry-list-scroll
      className="h-full overflow-y-auto overscroll-y-contain pt-2"
    >
      <div
        style={{ paddingTop, paddingBottom }}
        className="flex w-full flex-col gap-2"
      >
        {items.map((virtualItem) => {
          const isLoaderRow = virtualItem.index === visibleEntries.length;

          if (isLoaderRow) {
            return (
              <div
                key="loader"
                ref={loaderRef}
                data-entry-list-loader
                style={{
                  height: virtualItem.size,
                }}
                className="flex w-full items-center justify-center px-2"
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
              ref={virtualizer.measureElement}
              className="w-full"
              data-index={virtualItem.index}
              data-entry-id={entry.entryId}
            >
              <EntryRow
                entry={entry}
                isSelected={selectedEntryId === entry.entryId}
                onSelect={onSelectEntry}
                isRead={entry.isRead === true || isEntryRead(entry.entryId)}
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
