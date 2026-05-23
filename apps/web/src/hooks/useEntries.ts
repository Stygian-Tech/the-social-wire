"use client";

import { useEffect } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import {
  useInfiniteQuery,
  useQuery,
  useQueryClient,
  type QueryClient,
} from "@tanstack/react-query";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import type { EntryListItem, EntryDetail } from "@/lib/atprotoClient";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import { prefetchCachedImages } from "@/lib/imageBlobCache";
import {
  getEntryFromAppView,
  enrollAuthorsInAppView,
  isThinAppViewEnabled,
  listEntriesFromAppView,
} from "@/lib/thinAppViewClient";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/hooks/usePublicationSidebarData";
import { usePublicationSidebarProjection } from "@/hooks/usePublicationSidebarProjection";
import {
  appViewScopeFromProjection,
  type PublicationAppViewScope,
} from "@/lib/publicationProjectionClient";
import { useAuth } from "./useAuth";

export type { EntryListItem, EntryDetail };

export const ENTRIES_QUERY_KEY = (authorDid: string) =>
  ["entries", authorDid] as const;
export const ENTRY_DETAIL_QUERY_KEY = (entryId: string) =>
  ["entry", entryId] as const;

export type EntriesPage = { entries: EntryListItem[]; cursor?: string };

/** Matches {@link useEntries} `staleTime` / `prefetchInfiniteQuery` for entry lists. */
export const ENTRIES_QUERY_STALE_MS = 30_000;

function requireAppViewScope(
  projection:
    | import("@/lib/publicationProjectionClient").PublicationSidebarProjection
    | undefined,
  publicationKey: string
): PublicationAppViewScope {
  const scope = appViewScopeFromProjection(projection, publicationKey);
  if (!scope) {
    throw new Error(
      `Missing AppView scope for publication ${publicationKey}. Refresh the sidebar.`
    );
  }
  return scope;
}

/** Stop pagination when the server returns an empty page without advancing the cursor. */
export function entriesNextPageParam(
  lastPage: EntriesPage,
  _allPages: EntriesPage[],
  lastPageParam: string | undefined
): string | undefined {
  const cursor = lastPage.cursor;
  if (!cursor) return undefined;
  if (lastPage.entries.length === 0 && lastPageParam === cursor) {
    return undefined;
  }
  return cursor;
}

/**
 * Fetches a single infinite-query page of entries from Thin AppView.
 */
export async function fetchEntriesInfinitePage(args: {
  normalizedPublicationKey: string;
  pageParam: string | undefined;
  signal?: AbortSignal;
  oauthSession: OAuthSession;
  viewerDid?: string;
  articleFilter?: ArticleListFilter;
  queryClient?: QueryClient;
  maxEntries?: number;
}): Promise<EntriesPage> {
  const {
    normalizedPublicationKey: normalizedKey,
    pageParam,
    signal,
    oauthSession,
    viewerDid,
    articleFilter = "all",
    queryClient,
    maxEntries,
  } = args;

  if (!normalizedKey) return { entries: [], cursor: undefined };

  if (!isThinAppViewEnabled()) {
    throw new Error("Thin AppView is required for entry lists");
  }

  const projection =
    viewerDid != null
      ? queryClient?.getQueryData<
          import("@/lib/publicationProjectionClient").PublicationSidebarProjection
        >(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid))
      : undefined;

  const appViewScope = requireAppViewScope(projection, normalizedKey);

  if (!pageParam) {
    try {
      const { authorDid, publicationSiteUrls } = appViewScope;
      if (publicationSiteUrls.length > 0) {
        await enrollAuthorsInAppView(oauthSession, [], publicationSiteUrls);
      } else {
        await enrollAuthorsInAppView(oauthSession, [authorDid]);
      }
    } catch {
      /* best-effort backfill for recent posts missing from Jetstream index */
    }
  }

  return listEntriesFromAppView({
    publicationKey: normalizedKey,
    appViewScope,
    cursor: maxEntries == null ? (pageParam as string | undefined) : undefined,
    maxEntries,
    filter: articleFilter,
    oauthSession,
    signal,
  });
}

/**
 * Returns a paginated list of entries for a publication sidebar selection.
 */
export function useEntries(
  publicationKey: string | null,
  articleFilter: ArticleListFilter = "all"
) {
  const { session, getOAuthSession } = useAuth();
  const queryClient = useQueryClient();
  const normalizedKey = publicationKey ? normalizeAtRepoParam(publicationKey) : null;
  const projection = usePublicationSidebarProjection(session?.did);
  const appViewScope = normalizedKey
    ? appViewScopeFromProjection(projection, normalizedKey)
    : undefined;
  const scopePending = !!normalizedKey && !!session && !appViewScope;

  const query = useInfiniteQuery({
    queryKey: [...ENTRIES_QUERY_KEY(normalizedKey ?? ""), articleFilter] as const,
    queryFn: async ({ pageParam, signal }) => {
      if (!normalizedKey) return { entries: [], cursor: undefined };
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      return fetchEntriesInfinitePage({
        normalizedPublicationKey: normalizedKey,
        pageParam,
        signal,
        oauthSession: oauth,
        viewerDid: session?.did,
        articleFilter,
        queryClient,
      });
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: entriesNextPageParam,
    enabled: !!normalizedKey && !!session && !!appViewScope,
    staleTime: ENTRIES_QUERY_STALE_MS,
    refetchOnMount: "always",
    gcTime: 1000 * 60 * 60 * 24,
  });

  useEffect(() => {
    const pages = query.data?.pages;
    if (!pages?.length) return;
    prefetchCachedImages(
      pages.flatMap((page) =>
        page.entries.flatMap((entry) => [
          entry.thumbnailUrl,
          entry.thumbnailFallbackUrl,
        ])
      )
    );
  }, [query.data]);

  return { ...query, scopePending };
}

/**
 * Returns entry detail from Thin AppView (`GET /v1/appview/entry`).
 */
export function useEntry(entryId: string | null) {
  const { session, getOAuthSession } = useAuth();
  const normalizedId = entryId ? normalizeAtRepoParam(entryId) : null;

  return useQuery({
    queryKey: ENTRY_DETAIL_QUERY_KEY(normalizedId ?? ""),
    queryFn: async ({ signal }) => {
      if (!normalizedId) return null;
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      if (!isThinAppViewEnabled()) {
        throw new Error("Thin AppView is required for entry detail");
      }
      return getEntryFromAppView(oauth, normalizedId, signal);
    },
    enabled: !!normalizedId && !!session,
    staleTime: 5 * 60_000,
  });
}
