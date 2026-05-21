"use client";

import { useMemo } from "react";

import type { DiscoveredPublication } from "@/lib/atprotoClient";

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
        unreadCountsByPublicationId?.get(pub.publicationId) ?? 0
      );
    }
    return map;
  }, [publications, unreadCountsByPublicationId]);
}
