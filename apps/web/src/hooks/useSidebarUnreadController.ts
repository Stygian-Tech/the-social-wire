"use client";

import { useMemo } from "react";
import { useQueryClient } from "@tanstack/react-query";

import { useEntriesCacheEpoch } from "@/hooks/useEntriesCacheEpoch";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import {
  effectivePublicationUnreadCount,
  findUnreadCountInMap,
  sumUnreadForPublications,
} from "@/lib/unreadCounts";

export type SidebarUnreadControllerOptions = {
  publications: DiscoveredPublication[];
  unreadCountsByPublicationId: Map<string, number> | undefined;
  isEntryRead?: (entryId: string) => boolean;
  /** From {@link useReadState}; bumps when local read map changes. */
  readEpoch?: number;
  viewerDid?: string;
};

/**
 * Per-publication unread counts merging AppView baseline with local read state
 * for cached feed rows. Subscribes to entries-cache updates via {@link useEntriesCacheEpoch}.
 */
export function useSidebarUnreadController(
  options: SidebarUnreadControllerOptions
): Map<string, number> {
  const { publications, unreadCountsByPublicationId, isEntryRead, readEpoch, viewerDid } =
    options;
  const queryClient = useQueryClient();
  const entriesEpoch = useEntriesCacheEpoch();

  return useMemo(() => {
    void entriesEpoch;
    void readEpoch;
    const map = new Map<string, number>();
    for (const pub of publications) {
      const knownServerCount = unreadCountsByPublicationId
        ? findUnreadCountInMap(unreadCountsByPublicationId, pub.publicationId)
        : undefined;
      const serverCount = knownServerCount ?? 0;
      map.set(
        pub.publicationId,
        isEntryRead && viewerDid
          ? effectivePublicationUnreadCount(
              serverCount,
              queryClient,
              viewerDid,
              pub.publicationId,
              isEntryRead,
              { capRaiseToServerCount: knownServerCount != null }
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
    viewerDid,
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
