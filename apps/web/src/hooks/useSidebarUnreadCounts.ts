"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import type { InfiniteData } from "@tanstack/react-query";
import { useQueryClient } from "@tanstack/react-query";

import {
  ENTRIES_QUERY_KEY,
  type EntriesPage,
} from "@/hooks/useEntries";
import {
  normalizeAtRepoParam,
  type DiscoveredPublication,
} from "@/lib/atprotoClient";
import {
  countUnreadCachedEntries,
  flattenCachedInfiniteEntries,
} from "@/lib/unreadCounts";

function isEntriesListQueryKey(key: unknown): boolean {
  return Array.isArray(key) && key[0] === "entries";
}

/**
 * Per-publication unread counts derived **only** from the TanStack Query cache for
 * {@link ENTRIES_QUERY_KEY}. Does not fetch. Publications with no cached pages count as 0.
 */
export function useSidebarUnreadCounts(
  publications: DiscoveredPublication[],
  isEntryRead: (entryId: string) => boolean
): Map<string, number> {
  const queryClient = useQueryClient();
  const [entriesCacheEpoch, setEntriesCacheEpoch] = useState(0);
  const bumpRafRef = useRef<number | null>(null);

  useEffect(() => {
    const unsub = queryClient.getQueryCache().subscribe((event) => {
      const key = event?.query?.queryKey;
      if (!isEntriesListQueryKey(key)) return;
      if (bumpRafRef.current != null) return;

      const runBump = () => {
        bumpRafRef.current = null;
        setEntriesCacheEpoch((e) => e + 1);
      };

      bumpRafRef.current =
        typeof requestAnimationFrame === "function"
          ? requestAnimationFrame(runBump)
          : (setTimeout(runBump, 0) as unknown as number);
    });

    return () => {
      unsub();
      if (bumpRafRef.current != null) {
        if (typeof cancelAnimationFrame === "function") {
          cancelAnimationFrame(bumpRafRef.current);
        } else if (typeof clearTimeout === "function") {
          clearTimeout(bumpRafRef.current);
        }
        bumpRafRef.current = null;
      }
    };
  }, [queryClient]);

  return useMemo(() => {
    void entriesCacheEpoch;
    const map = new Map<string, number>();
    for (const pub of publications) {
      const normalized = normalizeAtRepoParam(pub.publicationId);
      const data = queryClient.getQueryData<InfiniteData<EntriesPage>>(
        ENTRIES_QUERY_KEY(normalized)
      );
      const entries = flattenCachedInfiniteEntries(data);
      const count = countUnreadCachedEntries(entries, isEntryRead);
      map.set(pub.publicationId, count);
    }
    return map;
  }, [publications, queryClient, isEntryRead, entriesCacheEpoch]);
}
