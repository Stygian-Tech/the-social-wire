import { coalesceFeedFirstPage } from "@/lib/feedRefreshCoordinator";
import type { InfiniteData, QueryClient } from "@tanstack/react-query";

import {
  ENTRIES_QUERY_KEY,
  ENTRIES_QUERY_STALE_MS,
  entriesNextPageParam,
  fetchEntriesInfinitePage,
  type EntriesPage,
} from "@/hooks/useEntries";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import { applyUnreadCountsEvent } from "@/lib/bootstrapStreamState";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { fetchAppViewUnreadCounts } from "@/lib/thinAppViewClient";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { mergeFeedRefreshForFilter } from "@/lib/feedCacheMerge";

export { mergeFeedFirstPageRefresh } from "@/lib/feedCacheMerge";

/** Delay after bootstrap before a one-time feed refresh (background enroll may still be running). */
export const FEED_POST_BOOTSTRAP_REFRESH_MS = 1_000;

/** Poll interval for the active publication feed while the tab is visible. */
export const FEED_PROACTIVE_REFRESH_INTERVAL_MS = 45_000;

/**
 * Merges a fresh first page into an infinite-query cache — new posts prepend without
 * dropping paginated tail pages (social-feed style).
 */
/** Refreshes AppView unread badge for one publication after feed changes. */
export async function refreshPublicationUnreadCount(args: {
  queryClient: QueryClient;
  viewerDid: string;
  publicationId: string;
  oauthSession: OAuthSession;
}): Promise<void> {
  const { queryClient, viewerDid, publicationId, oauthSession } = args;
  try {
    const countSnapshot = await fetchAppViewUnreadCounts(oauthSession, [
      publicationId,
    ]);
    queryClient.setQueryData<PublicationSidebarProjection>(
      PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid),
      (current) =>
        current
          ? applyUnreadCountsEvent(current, countSnapshot.counts, {
              replacePublicationIds: [publicationId],
              generation: countSnapshot.generation,
              accuracy: countSnapshot.accuracy,
              countedAt: countSnapshot.countedAt,
            })
          : current
    );
  } catch {
    /* best-effort badge sync */
  }
}

type FeedRefreshArgs = {
  queryClient: QueryClient;
  publicationKey: string;
  articleFilter?: ArticleListFilter;
  oauthSession: OAuthSession;
  viewerDid?: string;
  /** When true, skips PDS enroll (lighter poll/focus refresh). */
  skipEnroll?: boolean;
  signal?: AbortSignal;
  /** Bootstrap recovery may fetch an absent cache through the normal query. */
  allowCacheMiss?: boolean;
};

const inFlightRefreshes = new WeakMap<QueryClient, WeakMap<object, Map<string, Promise<boolean>>>>();

/** Focus, visibility and bootstrap callers share one refresh for a viewer/scope. */
export function refreshPublicationFeedFirstPage(args: FeedRefreshArgs): Promise<boolean> {
  let sessions = inFlightRefreshes.get(args.queryClient);
  if (!sessions) { sessions = new WeakMap(); inFlightRefreshes.set(args.queryClient, sessions); }
  let pending = sessions.get(args.oauthSession);
  if (!pending) { pending = new Map(); sessions.set(args.oauthSession, pending); }
  const key = JSON.stringify([args.viewerDid, normalizeAtRepoParam(args.publicationKey), args.articleFilter ?? "all", args.allowCacheMiss ?? false]);
  const existing = pending.get(key);
  if (existing) return existing;
  const task = performPublicationFeedRefresh({ ...args, publicationKey: normalizeAtRepoParam(args.publicationKey) }).finally(() => {
    if (pending.get(key) === task) pending.delete(key);
  });
  pending.set(key, task);
  return task;
}

async function performPublicationFeedRefresh(args: FeedRefreshArgs): Promise<boolean> {
  const {
    queryClient,
    publicationKey,
    articleFilter = "all",
    oauthSession,
    viewerDid,
    skipEnroll = false,
    signal,
    allowCacheMiss = false,
  } = args;

  if (!viewerDid) return false;
  const queryKey = [
    ...ENTRIES_QUERY_KEY(viewerDid, publicationKey),
    articleFilter,
  ] as const;
  const existing = queryClient.getQueryData<InfiniteData<EntriesPage>>(queryKey);
  if (!existing?.pages.length) {
    if (!allowCacheMiss) return false;
    // The same query key coalesces with an already mounted feed's initial fetch.
    await queryClient.fetchInfiniteQuery({
      queryKey,
      initialPageParam: undefined as string | undefined,
      getNextPageParam: entriesNextPageParam,
      staleTime: ENTRIES_QUERY_STALE_MS,
      retry: false,
      queryFn: ({ pageParam, signal: querySignal }) => fetchEntriesInfinitePage({
        normalizedPublicationKey: publicationKey,
        pageParam,
        signal: querySignal,
        oauthSession,
        viewerDid,
        articleFilter,
        queryClient,
        skipEnroll,
      }),
    });
    return true;
  }

  const freshPage = await coalesceFeedFirstPage(queryClient, oauthSession, queryKey, () => fetchEntriesInfinitePage({
    normalizedPublicationKey: publicationKey,
    pageParam: undefined,
    signal,
    oauthSession,
    viewerDid,
    articleFilter,
    queryClient,
    skipEnroll,
  }));

  queryClient.setQueryData<InfiniteData<EntriesPage>>(queryKey, (current) =>
    mergeFeedRefreshForFilter(current, freshPage, articleFilter)
  );

  if (viewerDid) {
    await refreshPublicationUnreadCount({
      queryClient,
      viewerDid,
      publicationId: normalizeAtRepoParam(publicationKey),
      oauthSession,
    });
  }
  return true;
}
