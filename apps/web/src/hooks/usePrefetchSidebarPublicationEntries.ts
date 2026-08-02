"use client";

import { useEffect, useMemo } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";

import { useAuth } from "@/hooks/useAuth";
import {
  ENTRIES_QUERY_KEY,
  ENTRIES_QUERY_STALE_MS,
  entriesNextPageParam,
  fetchEntriesInfinitePage,
} from "@/hooks/useEntries";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";

/** Delay before background prefetch of non-selected sidebar publications. */
const BULK_PREFETCH_DELAY_MS = 8_000;

/** Max parallel first-page prefetches per batch (avoids flooding the network). */
const PREFETCH_CONCURRENCY = 2;

/** Bound background prefetch to likely next taps instead of the full sidebar. */
const MAX_BACKGROUND_PREFETCH_PUBLICATIONS = 8;

/** Default article filter used by {@link useEntries} when opening a publication feed. */
const PREFETCH_ARTICLE_FILTER = "all" as const;

/** Selected publication first, then the rest in stable sidebar order. */
export function orderPublicationIdsForPrefetch(
  publicationIds: string[],
  selectedPublicationId: string | null,
  unreadCountsByPublicationId?: ReadonlyMap<string, number>
): string[] {
  const unique = [
    ...new Set(publicationIds.map((id) => normalizeAtRepoParam(id))),
  ];
  const unreadCount = (publicationId: string) =>
    unreadCountsByPublicationId?.get(publicationId) ??
    unreadCountsByPublicationId?.get(normalizeAtRepoParam(publicationId)) ??
    0;

  const selected = selectedPublicationId
    ? normalizeAtRepoParam(selectedPublicationId)
    : null;
  const selectedPart = selected && unique.includes(selected) ? [selected] : [];
  const remaining = unique.filter((id) => id !== selected);
  const unreadPart = remaining
    .filter((id) => unreadCount(id) > 0)
    .sort((a, b) => unreadCount(b) - unreadCount(a));
  const unreadSet = new Set(unreadPart);
  const visiblePart = remaining.filter((id) => !unreadSet.has(id));

  return [...selectedPart, ...unreadPart, ...visiblePart].slice(
    0,
    MAX_BACKGROUND_PREFETCH_PUBLICATIONS
  );
}

function waitForBackgroundPrefetchWindow(delayMs: number): Promise<void> {
  return new Promise((resolve) => {
    window.setTimeout(() => {
      if ("requestIdleCallback" in window) {
        window.requestIdleCallback(() => resolve(), { timeout: 4_000 });
        return;
      }
      resolve();
    }, delayMs);
  });
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
      ...ENTRIES_QUERY_KEY(viewerDid, normalizedPublicationId),
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
        // Sidebar already enrolls authors after bootstrap; skip per-prefetch enroll to avoid AppView DB stampedes.
        skipEnroll: true,
      }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: entriesNextPageParam,
    staleTime: ENTRIES_QUERY_STALE_MS,
  });
}

/**
 * Prefetches the first page (50 entries) for visible sidebar publications so opening a
 * feed can reuse cached data. Runs in the background with limited concurrency; the
 * active selection is prefetched immediately when it changes.
 */
export function usePrefetchSidebarPublicationEntries(
  publications: DiscoveredPublication[],
  enabled: boolean,
  selectedPublicationId: string | null,
  unreadCountsByPublicationId?: ReadonlyMap<string, number>
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

      await waitForBackgroundPrefetchWindow(BULK_PREFETCH_DELAY_MS);
      if (cancelled) return;

      const orderedIds = orderPublicationIdsForPrefetch(
        sidebarPublicationIds,
        selectedPublicationId,
        unreadCountsByPublicationId
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
  }, [
    enabled,
    session,
    idsKey,
    queryClient,
    getOAuthSession,
    sidebarPublicationIds,
    selectedPublicationId,
    unreadCountsByPublicationId,
  ]);
}
