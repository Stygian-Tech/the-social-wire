import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { InfiniteData, QueryClient, QueryKey } from "@tanstack/react-query";

import type { EntriesPage } from "@/hooks/useEntries";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import { awaitWithAbort } from "@/lib/awaitWithAbort";
import { advanceFeedRefreshRevision, getFeedRefreshRevision, readFeedRefreshRevision } from "@/lib/feedRefreshCoordinator";
import { mergeFeedRefreshForFilter } from "@/lib/feedCacheMerge";
import {
  listAggregateFeedFromAppView,
  type AggregateAppViewFeed,
} from "@/lib/thinAppViewClient";

function feedScope(queryKey: QueryKey): {
  feed: AggregateAppViewFeed;
  filter: ArticleListFilter;
} | undefined {
  if (
    queryKey[0] === "entries" && queryKey.length === 4 &&
    typeof queryKey[2] === "string" && queryKey[2]
  ) {
    const filter = queryKey[3];
    if (filter === "all" || filter === "unread") {
      return { feed: { kind: "publication", id: queryKey[2] }, filter };
    }
  }
  if (
    queryKey[0] === "aggregateEntries" && queryKey.length === 5 &&
    typeof queryKey[3] === "string"
  ) {
    const kind = queryKey[2];
    const filter = queryKey[4];
    if (
      (kind === "subscribed" || kind === "following" || kind === "folder" ||
        kind === "publication" || kind === "list") &&
      (filter === "all" || filter === "unread")
    ) {
      return { feed: { kind, id: queryKey[3] }, filter };
    }
  }
}

/** Reconcile mounted feeds after reader refresh without reloading paginated history. */
export async function refreshReaderFeeds({
  queryClient,
  viewerDid,
  oauthSession,
  signal: callerSignal,
  onNewArticleIds,
  isCurrentSession,
}: {
  queryClient: QueryClient;
  viewerDid: string;
  oauthSession: OAuthSession;
  signal?: AbortSignal;
  onNewArticleIds?: (ids: readonly string[]) => void;
  isCurrentSession?: () => boolean;
}): Promise<{ newArticleCount: number }> {
  const signal = AbortSignal.any([...(callerSignal ? [callerSignal] : []), AbortSignal.timeout(30_000)]);
  signal.throwIfAborted();
  if (!viewerDid) return { newArticleCount: 0 };
  const assertSession = () => {
    signal.throwIfAborted();
    if (isCurrentSession && !isCurrentSession()) throw new DOMException("Account changed", "AbortError");
  };
  assertSession();
  const readRevision = readFeedRefreshRevision(queryClient, oauthSession);
  const generations = new Map<string, number>();
  const filters = {
    predicate: (query: { queryKey: QueryKey }) =>
      query.queryKey[1] === viewerDid && feedScope(query.queryKey) !== undefined,
  };

  // Cancellation can restore pre-request data/state. Await it before invalidating
  // or reading the merge baseline so an older request cannot undo the refresh.
  for (const query of queryClient.getQueryCache().findAll(filters)) {
    generations.set(query.queryHash, advanceFeedRefreshRevision(queryClient, query.queryKey));
  }
  await queryClient.cancelQueries(filters);
  assertSession();
  await queryClient.invalidateQueries({ ...filters, refetchType: "none" });
  assertSession();
  const activeQueries = queryClient.getQueryCache().findAll({ ...filters, type: "active" });
  const previousIds = new Set(activeQueries.flatMap(query =>
    (query.state.data as InfiniteData<EntriesPage> | undefined)?.pages.flatMap(page =>
      page.entries.map(entry => entry.entryId)
    ) ?? []
  ));
  const addedIds = new Set<string>();
  let nextIndex = 0;
  let failed = false;
  const refreshNext = async () => {
    while (!failed && nextIndex < activeQueries.length) {
      assertSession();
      const query = activeQueries[nextIndex++];
      const scope = feedScope(query.queryKey)!;
      try {
        const freshPage = await awaitWithAbort(listAggregateFeedFromAppView({
          ...scope,
          oauthSession,
          signal,
        }), signal);
        assertSession();
        // Read gestures own their flags; a response from before a gesture or a
        // newer manual refresh cannot replace the current cache.
        if (readFeedRefreshRevision(queryClient, oauthSession) !== readRevision ||
            getFeedRefreshRevision(queryClient, query.queryKey) !== generations.get(query.queryHash)) continue;
        queryClient.setQueryData<InfiniteData<EntriesPage>>(query.queryKey, current =>
          mergeFeedRefreshForFilter(current, freshPage, scope.filter)
        );
        for (const entry of freshPage.entries) {
          if (!previousIds.has(entry.entryId)) addedIds.add(entry.entryId);
        }
      } catch (error) {
        failed = true;
        throw error;
      }
    }
  };
  // Settle all workers before returning a failure; no cache writes continue after
  // the caller handles that failure or starts a retry.
  const results = await Promise.allSettled(
    Array.from({ length: Math.min(3, activeQueries.length) }, refreshNext)
  );
  for (const result of results) {
    if (result.status === "rejected") throw result.reason;
  }
  assertSession();
  onNewArticleIds?.([...addedIds]);
  return { newArticleCount: addedIds.size };
}
