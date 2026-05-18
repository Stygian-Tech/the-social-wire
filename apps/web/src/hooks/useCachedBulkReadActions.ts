"use client";

import { useCallback, useMemo } from "react";
import { useQueryClient } from "@tanstack/react-query";

import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useEntriesCacheEpoch } from "@/hooks/useEntriesCacheEpoch";
import { distinctCachedEntryIdsForPublications } from "@/lib/unreadCounts";
import type { DiscoveredPublication } from "@/lib/atprotoClient";

export function useCachedBulkReadActions(
  publications: DiscoveredPublication[]
) {
  const queryClient = useQueryClient();
  const entriesEpoch = useEntriesCacheEpoch();
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
    markEntriesRead(cachedEntryIds);
  }, [markEntriesRead, cachedEntryIds]);

  const applyMarkAllUnread = useCallback(() => {
    markEntriesUnread(cachedEntryIds);
  }, [markEntriesUnread, cachedEntryIds]);

  return {
    cachedEntryIds,
    bulkDisabled,
    applyMarkAllRead,
    applyMarkAllUnread,
  };
}
