"use client";

import { useEffect, useMemo } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";

import { useAuth } from "@/hooks/useAuth";
import {
  ENTRIES_QUERY_KEY,
  ENTRIES_QUERY_STALE_MS,
  fetchEntriesInfinitePage,
  type EntriesPage,
} from "@/hooks/useEntries";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";

/** Max entries to warm in background sidebar prefetch (server-side aggregation). */
const PREFETCH_MAX_ENTRIES = 120;

/** Max parallel first-page prefetches per batch (avoids flooding the network). */
const PREFETCH_CONCURRENCY = 2;

/** Default article filter used by {@link useEntries} when opening a publication feed. */
const PREFETCH_ARTICLE_FILTER = "all" as const;

/** Selected publication first, then the rest in stable sidebar order. */
export function orderPublicationIdsForPrefetch(
  publicationIds: string[],
  selectedPublicationId: string | null
): string[] {
  const unique = [
    ...new Set(publicationIds.map((id) => normalizeAtRepoParam(id))),
  ];
  if (!selectedPublicationId) return unique;

  const selected = normalizeAtRepoParam(selectedPublicationId);
  if (!unique.includes(selected)) return unique;
  return [selected, ...unique.filter((id) => id !== selected)];
}

async function prefetchPublicationFirstPage(args: {
  queryClient: ReturnType<typeof useQueryClient>;
  normalizedPublicationId: string;
  oauthSession: OAuthSession;
  viewerDid: string;
}): Promise<void> {
  const { queryClient, normalizedPublicationId, oauthSession, viewerDid } = args;

  await queryClient.prefetchInfiniteQuery({
    queryKey: [
      ...ENTRIES_QUERY_KEY(normalizedPublicationId),
      PREFETCH_ARTICLE_FILTER,
    ] as const,
    queryFn: ({ pageParam, signal: querySignal }) =>
      fetchEntriesInfinitePage({
        normalizedPublicationKey: normalizedPublicationId,
        pageParam,
        signal: querySignal,
        oauthSession: oauthSession,
        viewerDid,
        articleFilter: PREFETCH_ARTICLE_FILTER,
        queryClient,
        maxEntries: PREFETCH_MAX_ENTRIES,
      }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (last: EntriesPage) => last.cursor,
    staleTime: ENTRIES_QUERY_STALE_MS,
  });
}

/**
 * Prefetches the first page of entries for visible sidebar publications so opening a
 * feed can reuse cached data. Runs in the background with limited concurrency; the
 * active selection is prefetched immediately when it changes.
 */
export function usePrefetchSidebarPublicationEntries(
  publications: DiscoveredPublication[],
  enabled: boolean,
  selectedPublicationId: string | null
) {
  const queryClient = useQueryClient();
  const { session, getOAuthSession } = useAuth();

  const sidebarPublicationIds = useMemo(
    () =>
      [
        ...new Set(
          publications.map((p) => normalizeAtRepoParam(p.publicationId))
        ),
      ],
    [publications]
  );

  const idsKey = useMemo(
    () => [...sidebarPublicationIds].sort().join("\x1e"),
    [sidebarPublicationIds]
  );

  useEffect(() => {
    if (!enabled || !session || !selectedPublicationId) return;

    const normalized = normalizeAtRepoParam(selectedPublicationId);
    if (!sidebarPublicationIds.includes(normalized)) return;

    void (async () => {
      const oauth = getOAuthSession();
      if (!oauth) return;
      try {
        await prefetchPublicationFirstPage({
          queryClient,
          normalizedPublicationId: normalized,
          oauthSession: oauth,
          viewerDid: session.did,
        });
      } catch {
        /* AppView / offline — keep sidebar usable */
      }
    })();
  }, [
    enabled,
    session,
    selectedPublicationId,
    sidebarPublicationIds,
    queryClient,
    getOAuthSession,
  ]);

  useEffect(() => {
    if (!enabled || !session || sidebarPublicationIds.length === 0) return;

    let cancelled = false;

    void (async () => {
      const oauth = getOAuthSession();
      if (!oauth) return;

      const orderedIds = orderPublicationIdsForPrefetch(
        sidebarPublicationIds,
        null
      );

      for (let i = 0; i < orderedIds.length; i += PREFETCH_CONCURRENCY) {
        if (cancelled) return;
        const chunk = orderedIds.slice(i, i + PREFETCH_CONCURRENCY);
        await Promise.all(
          chunk.map(async (normalized) => {
            try {
              await prefetchPublicationFirstPage({
                queryClient,
                normalizedPublicationId: normalized,
                oauthSession: oauth,
                viewerDid: session.did,
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
  }, [enabled, session, idsKey, queryClient, getOAuthSession, sidebarPublicationIds]);
}
