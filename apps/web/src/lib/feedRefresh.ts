import type { InfiniteData, QueryClient } from "@tanstack/react-query";

import {
  ENTRIES_QUERY_KEY,
  fetchEntriesInfinitePage,
  type EntriesPage,
} from "@/hooks/useEntries";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/hooks/usePublicationSidebarData";
import { applyUnreadCountsEvent } from "@/lib/bootstrapStreamState";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import { dedupeEntryListItems } from "@/lib/rssFeedCore";
import { fetchAppViewUnreadCounts } from "@/lib/thinAppViewClient";
import type { OAuthSession } from "@atproto/oauth-client-browser";

/** Delay after bootstrap before a one-time feed refresh (background enroll may still be running). */
export const FEED_POST_BOOTSTRAP_REFRESH_MS = 2_500;

/** Poll interval for the active publication feed while the tab is visible. */
export const FEED_PROACTIVE_REFRESH_INTERVAL_MS = 45_000;

/**
 * Merges a fresh first page into an infinite-query cache — new posts prepend without
 * dropping paginated tail pages (social-feed style).
 */
export function mergeFeedFirstPageRefresh(
  existing: InfiniteData<EntriesPage> | undefined,
  freshPage: EntriesPage
): InfiniteData<EntriesPage> {
  if (!existing?.pages.length) {
    return { pages: [freshPage], pageParams: [undefined] };
  }

  const [firstPage, ...restPages] = existing.pages;
  const [firstParam, ...restParams] = existing.pageParams;

  const freshIds = new Set(freshPage.entries.map((entry) => entry.entryId));
  const carryOver = firstPage.entries.filter((entry) => !freshIds.has(entry.entryId));
  const mergedFirst: EntriesPage = {
    entries: dedupeEntryListItems([...freshPage.entries, ...carryOver]),
    cursor: freshPage.cursor ?? firstPage.cursor,
  };

  return {
    pages: [mergedFirst, ...restPages],
    pageParams: [firstParam, ...restParams],
  };
}

/** Refreshes AppView unread badge for one publication after feed changes. */
export async function refreshPublicationUnreadCount(args: {
  queryClient: QueryClient;
  viewerDid: string;
  publicationId: string;
  oauthSession: OAuthSession;
}): Promise<void> {
  const { queryClient, viewerDid, publicationId, oauthSession } = args;
  try {
    const counts = await fetchAppViewUnreadCounts(oauthSession, [publicationId]);
    queryClient.setQueryData<PublicationSidebarProjection>(
      PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid),
      (current) =>
        current
          ? applyUnreadCountsEvent(current, counts, {
              replacePublicationIds: [publicationId],
            })
          : current
    );
  } catch {
    /* best-effort badge sync */
  }
}

export async function refreshPublicationFeedFirstPage(args: {
  queryClient: QueryClient;
  publicationKey: string;
  articleFilter?: ArticleListFilter;
  oauthSession: OAuthSession;
  viewerDid?: string;
  /** When true, skips PDS enroll (lighter poll/focus refresh). */
  skipEnroll?: boolean;
  signal?: AbortSignal;
}): Promise<boolean> {
  const {
    queryClient,
    publicationKey,
    articleFilter = "all",
    oauthSession,
    viewerDid,
    skipEnroll = false,
    signal,
  } = args;

  const queryKey = [...ENTRIES_QUERY_KEY(publicationKey), articleFilter] as const;
  const existing = queryClient.getQueryData<InfiniteData<EntriesPage>>(queryKey);
  if (!existing?.pages.length) return false;

  const freshPage = await fetchEntriesInfinitePage({
    normalizedPublicationKey: publicationKey,
    pageParam: undefined,
    signal,
    oauthSession,
    viewerDid,
    articleFilter,
    queryClient,
    skipEnroll,
  });

  queryClient.setQueryData<InfiniteData<EntriesPage>>(queryKey, (current) =>
    mergeFeedFirstPageRefresh(current, freshPage)
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
