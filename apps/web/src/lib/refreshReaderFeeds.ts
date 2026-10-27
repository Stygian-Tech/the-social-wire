import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { InfiniteData, QueryClient, QueryKey } from "@tanstack/react-query";

import type { EntriesPage } from "@/hooks/useEntries";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import { awaitWithAbort } from "@/lib/awaitWithAbort";
import { advanceFeedRefreshRevision, getFeedRefreshRevision } from "@/lib/feedRefreshCoordinator";
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
}: {
  queryClient: QueryClient;
  viewerDid: string;
  oauthSession: OAuthSession;
  signal?: AbortSignal;
}): Promise<{ newArticleCount: number }> {
  const signal = AbortSignal.any([...(callerSignal ? [callerSignal] : []), AbortSignal.timeout(30_000)]);
  signal.throwIfAborted();
  if (!viewerDid) return { newArticleCount: 0 };
  const filters = {
    predicate: (query: { queryKey: QueryKey }) =>
      query.queryKey[1] === viewerDid && feedScope(query.queryKey) !== undefined,
  };

  // Cancellation can restore pre-request data/state. Await it before invalidating
  // or reading the merge baseline so an older request cannot undo the refresh.
  const revisions = new Map<string, number>();
  for (const query of queryClient.getQueryCache().findAll(filters)) {
    revisions.set(query.queryHash, advanceFeedRefreshRevision(queryClient, query.queryKey));
  }
  await queryClient.cancelQueries(filters);
  signal?.throwIfAborted();
  await queryClient.invalidateQueries({ ...filters, refetchType: "none" });
  signal?.throwIfAborted();
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
      signal?.throwIfAborted();
      const query = activeQueries[nextIndex++];
      const scope = feedScope(query.queryKey)!;
      try {
        const freshPage = await awaitWithAbort(listAggregateFeedFromAppView({
          ...scope,
          oauthSession,
          signal,
        }), signal);
        signal?.throwIfAborted();
        if (getFeedRefreshRevision(queryClient, query.queryKey) !== revisions.get(query.queryHash)) continue;
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
  signal?.throwIfAborted();
  return { newArticleCount: addedIds.size };
}
