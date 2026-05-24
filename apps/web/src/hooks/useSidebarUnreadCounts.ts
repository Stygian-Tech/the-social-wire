"use client";

import { useMemo } from "react";

import { normalizeAtRepoParam, type DiscoveredPublication } from "@/lib/atprotoClient";

function lookupUnreadCount(
  unreadCountsByPublicationId: Map<string, number>,
  publicationId: string
): number {
  const target = normalizeAtRepoParam(publicationId);
  for (const [key, count] of unreadCountsByPublicationId) {
    if (normalizeAtRepoParam(key) === target) return count;
  }
  return unreadCountsByPublicationId.get(publicationId) ?? 0;
}

/**
 * Per-publication unread counts from gateway sidebar projection or
 * `GET /v1/appview/unread-counts` (via {@link usePublicationSidebarData}).
 */
export function useSidebarUnreadCounts(
  publications: DiscoveredPublication[],
  unreadCountsByPublicationId: Map<string, number> | undefined
): Map<string, number> {
  return useMemo(() => {
    const map = new Map<string, number>();
    for (const pub of publications) {
      map.set(
        pub.publicationId,
        unreadCountsByPublicationId
          ? lookupUnreadCount(unreadCountsByPublicationId, pub.publicationId)
          : 0
      );
    }
    return map;
  }, [publications, unreadCountsByPublicationId]);
}
