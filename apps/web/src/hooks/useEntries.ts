"use client";

import {
  useInfiniteQuery,
  useQuery,
  useQueryClient,
  type InfiniteData,
} from "@tanstack/react-query";
import { listEntries, getEntry } from "@/lib/atprotoClient";
import type { EntryListItem, EntryDetail } from "@/lib/atprotoClient";
import { useAuth } from "./useAuth";

export type { EntryListItem, EntryDetail };

export const ENTRIES_QUERY_KEY = (authorDid: string) =>
  ["entries", authorDid] as const;
export const ENTRY_DETAIL_QUERY_KEY = (entryId: string) =>
  ["entry", entryId] as const;

/**
 * Returns a paginated list of entries for a publication.
 *
 * `authorDid` is the DID of the publication's author. Entries are fetched
 * directly from the ATProto network — no Social Wire service required.
 */
type EntriesPage = { entries: EntryListItem[]; cursor?: string };

export function useEntries(authorDid: string | null) {
  const { session, getOAuthSession } = useAuth();
  const queryClient = useQueryClient();

  return useInfiniteQuery({
    queryKey: ENTRIES_QUERY_KEY(authorDid ?? ""),
    queryFn: async ({ pageParam, signal }) => {
      if (!authorDid) return { entries: [], cursor: undefined };
      const oauth = getOAuthSession() ?? undefined;
      const key = ENTRIES_QUERY_KEY(authorDid);
      const isFirstInfinitePage = pageParam === undefined;
      return listEntries(
        authorDid,
        pageParam as string | undefined,
        50,
        oauth,
        {
          signal,
          onProgress: isFirstInfinitePage
            ? ({ entries, cursor }) => {
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
            : undefined,
        }
      );
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) => lastPage.cursor,
    enabled: !!authorDid && !!session,
    staleTime: 2 * 60_000,
    gcTime: 1000 * 60 * 60 * 24,
  });
}

/**
 * Returns the full content for a single entry by its AT-URI.
 */
export function useEntry(entryId: string | null) {
  const { session, getOAuthSession } = useAuth();

  return useQuery({
    queryKey: ENTRY_DETAIL_QUERY_KEY(entryId ?? ""),
    queryFn: async () => {
      if (!entryId) return null;
      return getEntry(entryId, getOAuthSession() ?? undefined);
    },
    enabled: !!entryId && !!session,
    staleTime: 5 * 60_000,
  });
}
