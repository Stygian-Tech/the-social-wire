"use client";

import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
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
export function useEntries(authorDid: string | null) {
  const { session } = useAuth();

  return useInfiniteQuery({
    queryKey: ENTRIES_QUERY_KEY(authorDid ?? ""),
    queryFn: async ({ pageParam }) => {
      if (!authorDid) return { entries: [], cursor: undefined };
      return listEntries(authorDid, pageParam as string | undefined);
    },
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) => lastPage.cursor,
    enabled: !!authorDid && !!session,
    staleTime: 2 * 60_000,
  });
}

/**
 * Returns the full content for a single entry by its AT-URI.
 */
export function useEntry(entryId: string | null) {
  const { session } = useAuth();

  return useQuery({
    queryKey: ENTRY_DETAIL_QUERY_KEY(entryId ?? ""),
    queryFn: async () => {
      if (!entryId) return null;
      return getEntry(entryId);
    },
    enabled: !!entryId && !!session,
    staleTime: 5 * 60_000,
  });
}
