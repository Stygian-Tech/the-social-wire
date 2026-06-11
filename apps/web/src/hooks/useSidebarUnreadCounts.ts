"use client";

import type { DiscoveredPublication } from "@/lib/atprotoClient";
import { useSidebarUnreadController } from "@/hooks/useSidebarUnreadController";

/**
 * @deprecated Prefer {@link useSidebarUnreadController}.
 */
export function useSidebarUnreadCounts(
  publications: DiscoveredPublication[],
  unreadCountsByPublicationId: Map<string, number> | undefined,
  options?: {
    isEntryRead?: (entryId: string) => boolean;
  }
): Map<string, number> {
  return useSidebarUnreadController({
    publications,
    unreadCountsByPublicationId,
    isEntryRead: options?.isEntryRead,
  });
}
