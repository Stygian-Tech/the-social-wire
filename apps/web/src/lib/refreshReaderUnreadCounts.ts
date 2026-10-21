import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { QueryClient } from "@tanstack/react-query";
import { readFeedRefreshRevision } from "@/lib/feedRefreshCoordinator";
import { applyUnreadCountsEvent } from "@/lib/bootstrapStreamState";
import { awaitWithAbort } from "@/lib/awaitWithAbort";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import { fetchAppViewUnreadCounts } from "@/lib/thinAppViewClient";

/** Ingestion changes badge totals after bootstrap's count snapshot has already arrived. */
export async function refreshReaderUnreadCounts(args: {
  queryClient: QueryClient;
  viewerDid: string;
  oauthSession: OAuthSession;
  publicationIds: string[];
  signal: AbortSignal;
  isCurrentSession?: () => boolean;
}): Promise<void> {
  const revision = readFeedRefreshRevision(args.queryClient, args.oauthSession);
  const ids = [...new Set(args.publicationIds)];
  const signal = AbortSignal.any([args.signal, AbortSignal.timeout(30_000)]);
  for (let index = 0; index < ids.length; index += 50) {
    signal.throwIfAborted();
    const publicationIds = ids.slice(index, index + 50);
    const snapshot = await awaitWithAbort(fetchAppViewUnreadCounts(args.oauthSession, publicationIds, signal), signal);
    signal.throwIfAborted();
    if (args.isCurrentSession && !args.isCurrentSession()) throw new DOMException("Account changed", "AbortError");
    if (readFeedRefreshRevision(args.queryClient, args.oauthSession) !== revision) return;
    args.queryClient.setQueryData<PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(args.viewerDid), current => current ? applyUnreadCountsEvent(current, snapshot.counts, {
      replacePublicationIds: publicationIds,
      generation: snapshot.generation,
      accuracy: snapshot.accuracy,
      countedAt: snapshot.countedAt,
    }) : current);
  }
}
