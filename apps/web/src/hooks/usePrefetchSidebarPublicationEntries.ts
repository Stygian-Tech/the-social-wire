"use client";

import { useEffect, useMemo } from "react";
import { useQueryClient } from "@tanstack/react-query";

import { useAuth } from "@/hooks/useAuth";
import {
  ENTRIES_QUERY_KEY,
  ENTRIES_QUERY_STALE_MS,
  fetchEntriesInfinitePage,
  type EntriesPage,
} from "@/hooks/useEntries";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";

/** Max parallel first-page prefetches per batch (avoids flooding the network). */
const PREFETCH_CONCURRENCY = 4;

/**
 * Prefetches the first page of entries for every visible sidebar publication so unread counts
 * and the read tab can use cached data without opening each source first.
 */
export function usePrefetchSidebarPublicationEntries(
  publications: DiscoveredPublication[],
  enabled: boolean
) {
  const queryClient = useQueryClient();
  const { session, getOAuthSession } = useAuth();

  const idsKey = useMemo(
    () =>
      [...new Set(publications.map((p) => normalizeAtRepoParam(p.publicationId)))]
        .sort()
        .join("\x1e"),
    [publications]
  );

  useEffect(() => {
    if (!enabled || !session || publications.length === 0) return;

    let cancelled = false;
    const normalizedIds = [
      ...new Set(publications.map((p) => normalizeAtRepoParam(p.publicationId))),
    ];

    void (async () => {
      const oauth = getOAuthSession();
      if (!oauth) return;
      for (let i = 0; i < normalizedIds.length; i += PREFETCH_CONCURRENCY) {
        if (cancelled) return;
        const chunk = normalizedIds.slice(i, i + PREFETCH_CONCURRENCY);
        await Promise.all(
          chunk.map(async (normalized) => {
            try {
              await queryClient.prefetchInfiniteQuery({
                queryKey: ENTRIES_QUERY_KEY(normalized),
                queryFn: ({ pageParam, signal }) =>
                  fetchEntriesInfinitePage({
                    normalizedPublicationKey: normalized,
                    pageParam,
                    signal,
                    oauthSession: oauth,
                    viewerDid: session.did,
                    queryClient,
                  }),
                initialPageParam: undefined as string | undefined,
                getNextPageParam: (last: EntriesPage) => last.cursor,
                staleTime: ENTRIES_QUERY_STALE_MS,
              });
            } catch {
              /* AppView / offline — keep sidebar usable */
            }
          })
        );
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [enabled, session, idsKey, queryClient, getOAuthSession, publications.length]);
}
