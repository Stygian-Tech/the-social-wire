import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { InfiniteData, QueryClient, QueryKey } from "@tanstack/react-query";

import type { EntriesPage } from "@/hooks/useEntries";
import { awaitWithAbort } from "@/lib/awaitWithAbort";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import { mergeFeedRefreshForFilter } from "@/lib/feedCacheMerge";
import { advanceFeedRefreshRevision, coalesceFeedFirstPage, getFeedRefreshRevision } from "@/lib/feedRefreshCoordinator";
import { listAggregateFeedFromAppView, type AggregateAppViewFeed } from "@/lib/thinAppViewClient";

/** Refresh only the head and fence older pagination/read-state writes. */
export async function refreshAggregateFeed(args: {
  queryClient: QueryClient;
  queryKey: QueryKey;
  feed: AggregateAppViewFeed;
  filter: ArticleListFilter;
  oauthSession: OAuthSession;
  isCurrentSession: () => boolean;
  signal?: AbortSignal;
}) {
  const { queryClient, queryKey } = args;
  const signal = args.signal ?? AbortSignal.timeout(30_000);
  signal?.throwIfAborted();
  const revision = advanceFeedRefreshRevision(queryClient, queryKey);
  await queryClient.cancelQueries({ queryKey, exact: true });
  signal?.throwIfAborted();
  if (!args.isCurrentSession() || getFeedRefreshRevision(queryClient, queryKey) !== revision) return;
  const fresh = await awaitWithAbort(coalesceFeedFirstPage(queryClient, args.oauthSession, queryKey, () =>
    listAggregateFeedFromAppView({ feed: args.feed, filter: args.filter, oauthSession: args.oauthSession, signal }), signal
  ), signal);
  signal?.throwIfAborted();
  if (!args.isCurrentSession() || getFeedRefreshRevision(queryClient, queryKey) !== revision) return;
  queryClient.setQueryData<InfiniteData<EntriesPage>>(queryKey, current =>
    mergeFeedRefreshForFilter(current, fresh, args.filter)
  );
}
