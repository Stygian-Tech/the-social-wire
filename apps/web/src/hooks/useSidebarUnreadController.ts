"use client";

import { useMemo } from "react";
import { useQueryClient } from "@tanstack/react-query";

import { useEntriesCacheEpoch } from "@/hooks/useEntriesCacheEpoch";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import {
  effectivePublicationUnreadCount,
  lookupUnreadCountInMap,
  sumUnreadForPublications,
} from "@/lib/unreadCounts";

export type SidebarUnreadControllerOptions = {
  publications: DiscoveredPublication[];
  unreadCountsByPublicationId: Map<string, number> | undefined;
  isEntryRead?: (entryId: string) => boolean;
  /** From {@link useReadState}; bumps when local read map changes. */
  readEpoch?: number;
};

/**
 * Per-publication unread counts merging AppView baseline with local read state
 * for cached feed rows. Subscribes to entries-cache updates via {@link useEntriesCacheEpoch}.
 */
export function useSidebarUnreadController(
  options: SidebarUnreadControllerOptions
): Map<string, number> {
  const { publications, unreadCountsByPublicationId, isEntryRead, readEpoch } =
    options;
  const queryClient = useQueryClient();
  const entriesEpoch = useEntriesCacheEpoch();

  return useMemo(() => {
    const map = new Map<string, number>();
    for (const pub of publications) {
      const serverCount = unreadCountsByPublicationId
        ? lookupUnreadCountInMap(unreadCountsByPublicationId, pub.publicationId)
        : 0;
      map.set(
        pub.publicationId,
        isEntryRead
          ? effectivePublicationUnreadCount(
              serverCount,
              queryClient,
              pub.publicationId,
              isEntryRead,
              { capRaiseToServerCount: true }
            )
          : serverCount
      );
    }
    return map;
    // entriesEpoch drives recomputation when prefetch/bootstrap fills entry cache
  }, [
    publications,
    unreadCountsByPublicationId,
    isEntryRead,
    queryClient,
    entriesEpoch,
    readEpoch,
  ]);
}

/** Sum unread badges for a publication list (folder/section headers). */
export function useSidebarSectionUnreadSum(
  publications: DiscoveredPublication[],
  publicationUnreadCounts: Map<string, number>
): number {
  return useMemo(
    () => sumUnreadForPublications(publications, publicationUnreadCounts),
    [publications, publicationUnreadCounts]
  );
}
