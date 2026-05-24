"use client";

import { useCallback, useMemo } from "react";
import { useQueryClient } from "@tanstack/react-query";

import { useAuth } from "@/hooks/useAuth";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useEntriesCacheEpoch } from "@/hooks/useEntriesCacheEpoch";
import {
  markAllReadOnGateway,
  type GatewayMarkAllReadScope,
} from "@/lib/publicationProjectionClient";
import { distinctCachedEntryIdsForPublications } from "@/lib/unreadCounts";
import type { DiscoveredPublication } from "@/lib/atprotoClient";

export function useCachedBulkReadActions(
  publications: DiscoveredPublication[],
  options?: { gatewayScopes?: GatewayMarkAllReadScope[] }
) {
  const queryClient = useQueryClient();
  const entriesEpoch = useEntriesCacheEpoch();
  const { getOAuthSession } = useAuth();
  const {
    markEntriesRead,
    markEntriesUnread,
  } = useReadRoute();

  const cachedEntryIds = useMemo(() => {
    void entriesEpoch;
    return distinctCachedEntryIdsForPublications(queryClient, publications);
  }, [queryClient, publications, entriesEpoch]);

  const bulkDisabled = cachedEntryIds.length === 0;

  const applyMarkAllRead = useCallback(() => {
    markEntriesRead(cachedEntryIds, { publications });
    const oauth = getOAuthSession();
    const scopes =
      options?.gatewayScopes ??
      publications.map((publication) => ({
        kind: "publication" as const,
        publicationId: publication.publicationId,
      }));
    if (oauth && scopes.length > 0) {
      for (const scope of scopes) {
        void markAllReadOnGateway(oauth, scope).catch(() => {
          /* best-effort AppView scope mark-all-read */
        });
      }
    }
  }, [
    markEntriesRead,
    cachedEntryIds,
    publications,
    getOAuthSession,
    options?.gatewayScopes,
  ]);

  const applyMarkAllUnread = useCallback(() => {
    markEntriesUnread(cachedEntryIds, { publications });
  }, [markEntriesUnread, cachedEntryIds, publications]);

  return {
    cachedEntryIds,
    bulkDisabled,
    applyMarkAllRead,
    applyMarkAllUnread,
  };
}
