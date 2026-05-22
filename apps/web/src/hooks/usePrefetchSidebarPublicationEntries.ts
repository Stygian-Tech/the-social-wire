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
const PREFETCH_CONCURRENCY = 2;

/** Default article filter used by {@link useEntries} when opening a publication feed. */
const PREFETCH_ARTICLE_FILTER = "all" as const;

/**
 * Prefetches the first page of entries for visible sidebar publications so opening a
 * feed can reuse cached data. Only prefetches the active selection when set to avoid
 * flooding AppView immediately after sidebar load.
 */
export function usePrefetchSidebarPublicationEntries(
  publications: DiscoveredPublication[],
  enabled: boolean,
  selectedPublicationId: string | null
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
    const normalizedIds = selectedPublicationId
      ? [normalizeAtRepoParam(selectedPublicationId)]
      : [];

    if (normalizedIds.length === 0) return;

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
                queryKey: [
                  ...ENTRIES_QUERY_KEY(normalized),
                  PREFETCH_ARTICLE_FILTER,
                ] as const,
                queryFn: ({ pageParam, signal }) =>
                  fetchEntriesInfinitePage({
                    normalizedPublicationKey: normalized,
                    pageParam,
                    signal,
                    oauthSession: oauth,
                    viewerDid: session.did,
                    articleFilter: PREFETCH_ARTICLE_FILTER,
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
  }, [
    enabled,
    session,
    idsKey,
    queryClient,
    getOAuthSession,
    publications.length,
    selectedPublicationId,
  ]);
}
