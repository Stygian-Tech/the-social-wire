"use client";

import type { OAuthSession } from "@atproto/oauth-client-browser";
import {
  useInfiniteQuery,
  useQuery,
  useQueryClient,
  type InfiniteData,
  type QueryClient,
} from "@tanstack/react-query";
import {
  listEntries,
  getEntry,
  normalizeAtRepoParam,
  repoAndPublicationFilterFromPubId,
} from "@/lib/atprotoClient";
import type { EntryListItem, EntryDetail } from "@/lib/atprotoClient";
import {
  isRssEntryId,
  isRssPublicationId,
  normalizedFeedUrlFromRssPublicationId,
} from "@/lib/rssFeedCore";
import { useAuth } from "./useAuth";

export type { EntryListItem, EntryDetail };

export const ENTRIES_QUERY_KEY = (authorDid: string) =>
  ["entries", authorDid] as const;
export const ENTRY_DETAIL_QUERY_KEY = (entryId: string) =>
  ["entry", entryId] as const;

export type EntriesPage = { entries: EntryListItem[]; cursor?: string };

/** Matches {@link useEntries} `staleTime` / `prefetchInfiniteQuery` for entry lists. */
export const ENTRIES_QUERY_STALE_MS = 2 * 60_000;

/**
 * Fetches a single infinite-query page of entries — shared by {@link useEntries} and
 * {@link prefetchSidebarPublicationEntries}.
 */
export async function fetchEntriesInfinitePage(args: {
  normalizedPublicationKey: string;
  pageParam: string | undefined;
  signal?: AbortSignal;
  oauthSession: OAuthSession | undefined;
  /** When set with {@link streamFirstPageToCache}, merges streamed chunks into this cache. */
  queryClient?: QueryClient;
  /**
   * Live read tab: stream the first ATProto `listRecords` slice into the query cache.
   * Prefetch passes false so only the final merged page is written.
   */
  streamFirstPageToCache?: boolean;
}): Promise<EntriesPage> {
  const {
    normalizedPublicationKey: normalizedKey,
    pageParam,
    signal,
    oauthSession,
    queryClient,
    streamFirstPageToCache = false,
  } = args;

  if (!normalizedKey) return { entries: [], cursor: undefined };

  if (isRssPublicationId(normalizedKey)) {
    const feedUrl = normalizedFeedUrlFromRssPublicationId(normalizedKey);
    if (!feedUrl) return { entries: [], cursor: undefined };
    const sp = new URLSearchParams({
      url: feedUrl,
      limit: "50",
    });
    const cursorPage = typeof pageParam === "string" ? pageParam : undefined;
    if (cursorPage) sp.set("cursor", cursorPage);
    const res = await fetch(`/api/rss-feed?${sp.toString()}`, {
      signal,
    });
    if (!res.ok) {
      throw new Error("Could not load RSS feed");
    }
    const json = (await res.json()) as {
      items: EntryListItem[];
      nextCursor?: string;
    };
    return {
      entries: json.items ?? [],
      cursor: json.nextCursor,
    };
  }

  const key = ENTRIES_QUERY_KEY(normalizedKey);
  const { repoDid, publicationAtUri } =
    repoAndPublicationFilterFromPubId(normalizedKey);
  const isFirstInfinitePage = pageParam === undefined;
  const onProgress =
    streamFirstPageToCache && queryClient && isFirstInfinitePage
      ? (payload: { entries: EntryListItem[]; cursor?: string }) => {
          const { entries, cursor } = payload;
          queryClient.setQueryData<InfiniteData<EntriesPage> | undefined>(
            key,
            (old) => {
              const page: EntriesPage = { entries, cursor };
              if (!old?.pages.length) {
                return {
                  pages: [page],
                  pageParams: [undefined],
                };
              }
              const nextPages = [...old.pages];
              nextPages[0] = page;
              return { ...old, pages: nextPages };
            }
          );
        }
      : undefined;

  return listEntries(
    repoDid,
    pageParam as string | undefined,
    50,
    oauthSession,
    {
      signal,
      publicationAtUri,
      onProgress,
    }
  );
}

/**
 * Returns a paginated list of entries for a publication sidebar selection.
 *
 * `publicationKey` is either an **author DID** (legacy discovery row) or a **publication record
 * AT-URI** (distinct publication on an account).
 */
export function useEntries(publicationKey: string | null) {
  const { session, getOAuthSession } = useAuth();
  const queryClient = useQueryClient();
  const normalizedKey = publicationKey ? normalizeAtRepoParam(publicationKey) : null;

  return useInfiniteQuery({
    queryKey: ENTRIES_QUERY_KEY(normalizedKey ?? ""),
    queryFn: async ({ pageParam, signal }) => {
      if (!normalizedKey) return { entries: [], cursor: undefined };
      return fetchEntriesInfinitePage({
        normalizedPublicationKey: normalizedKey,
        pageParam,
        signal,
        oauthSession: getOAuthSession() ?? undefined,
        queryClient,
        streamFirstPageToCache: true,
      });
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) => lastPage.cursor,
    enabled: !!normalizedKey && !!session,
    staleTime: ENTRIES_QUERY_STALE_MS,
    gcTime: 1000 * 60 * 60 * 24,
  });
}

/**
 * Returns the full content for a single entry by its AT-URI.
 */
export function useEntry(entryId: string | null) {
  const { session, getOAuthSession } = useAuth();
  const normalizedId = entryId ? normalizeAtRepoParam(entryId) : null;

  return useQuery({
    queryKey: ENTRY_DETAIL_QUERY_KEY(normalizedId ?? ""),
    queryFn: async ({ signal }) => {
      if (!normalizedId) return null;
      if (isRssEntryId(normalizedId)) {
        const res = await fetch(
          `/api/rss-feed?entryId=${encodeURIComponent(normalizedId)}`,
          { signal }
        );
        if (!res.ok) return null;
        const json = (await res.json()) as {
          entry: EntryDetail | null;
        };
        return json.entry ?? null;
      }
      return getEntry(normalizedId, getOAuthSession() ?? undefined);
    },
    enabled: !!normalizedId && !!session,
    staleTime: 5 * 60_000,
  });
}
