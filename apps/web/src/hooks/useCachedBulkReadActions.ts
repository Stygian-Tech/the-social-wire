"use client";

import { useCallback, useMemo } from "react";
import {
  useQueryClient,
  type InfiniteData,
  type QueryKey,
} from "@tanstack/react-query";

import { useAuth } from "@/hooks/useAuth";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useEntriesCacheEpoch } from "@/hooks/useEntriesCacheEpoch";
import {
  markAllReadOnGateway,
  type GatewayMarkAllReadScope,
} from "@/lib/publicationProjectionClient";
import { distinctCachedEntryIdsForPublications } from "@/lib/unreadCounts";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import { applyUnreadCountsEvent } from "@/lib/bootstrapStreamState";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import type { EntriesPage } from "@/hooks/useEntries";

export function useCachedBulkReadActions(
  publications: DiscoveredPublication[],
  options?: { gatewayScopes?: GatewayMarkAllReadScope[] }
) {
  const queryClient = useQueryClient();
  const entriesEpoch = useEntriesCacheEpoch();
  const { session, getOAuthSession } = useAuth();
  const viewerDid = session?.did;
  const {
    markEntriesRead,
    markEntriesUnread,
    isEntryRead,
  } = useReadRoute();

  const cachedEntryIds = useMemo(() => {
    void entriesEpoch;
    return viewerDid
      ? distinctCachedEntryIdsForPublications(queryClient, viewerDid, publications)
      : [];
  }, [queryClient, publications, entriesEpoch, viewerDid]);

  const bulkDisabled =
    cachedEntryIds.length === 0 &&
    publications.length === 0 &&
    (options?.gatewayScopes?.length ?? 0) === 0;

  const applyMarkAllRead = useCallback(() => {
    const entryWasRead = isEntryRead ?? (() => false);
    const previouslyRead = cachedEntryIds.filter(entryWasRead);
    const newlyRead = cachedEntryIds.filter((entryId) => !entryWasRead(entryId));
    const cacheSnapshots = queryClient.getQueriesData<InfiniteData<EntriesPage>>({
      predicate: ({ queryKey }) =>
        queryKey[0] === "entries" || queryKey[0] === "aggregateEntries",
    });
    markEntriesRead(cachedEntryIds, {
      publications,
      syncToAppView: false,
    });
    for (const [queryKey, data] of cacheSnapshots) {
      if (!data) continue;
      queryClient.setQueryData<InfiniteData<EntriesPage>>(queryKey, {
        ...data,
        pages: data.pages.map((page) => ({
          ...page,
          entries: page.entries.map((entry) =>
            cachedEntryIds.includes(entry.entryId)
              ? { ...entry, isRead: true }
              : entry
          ),
        })),
      });
    }
    const oauth = getOAuthSession();
    const scopes =
      options?.gatewayScopes ??
      publications.map((publication) => ({
        kind: "publication" as const,
        publicationId: publication.publicationId,
      }));
    if (oauth && scopes.length > 0) {
      void Promise.all(scopes.map((scope) => markAllReadOnGateway(oauth, scope)))
        .then((confirmations) => {
          if (!viewerDid) return;
          const confirmedCounts = Object.assign(
            {},
            ...confirmations.map((confirmation) => confirmation.unreadCounts ?? {})
          ) as Record<string, number>;
          const replacePublicationIds = [
            ...new Set([
              ...publications.map((publication) => publication.publicationId),
              ...confirmations.flatMap((confirmation) =>
                (confirmation.boundaries ?? []).map(
                  (boundary) => boundary.publicationId
                )
              ),
              ...Object.keys(confirmedCounts),
            ]),
          ];
          const confirmedAt = confirmations
            .map((confirmation) => confirmation.confirmedAt)
            .filter(Boolean)
            .sort()
            .at(-1);
          queryClient.setQueryData<PublicationSidebarProjection>(
            PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid),
            (current) =>
              current
                ? applyUnreadCountsEvent(current, confirmedCounts, {
                    replacePublicationIds,
                    accuracy: "exact",
                    countedAt: confirmedAt,
                  })
                : current
          );
          // Entries that landed in the cache between the initial snapshot and
          // the gateway confirming (e.g. a background prefetch mid-flight)
          // never got an explicit local read mark. effectivePublicationUnreadCount
          // still counts those against isEntryRead, so without this they keep
          // showing up as unread even though the server's mark-all-read floor
          // now covers them. Re-snapshot and mark whatever's cached now.
          const settledEntryIds = distinctCachedEntryIdsForPublications(
            queryClient,
            viewerDid,
            publications
          );
          if (settledEntryIds.length > 0) {
            markEntriesRead(settledEntryIds, {
              publications,
              syncToAppView: false,
            });
          }
          // Persist the authoritative response immediately, then refetch to
          // reconcile any entries that arrived after the server boundary.
          void queryClient.invalidateQueries({
            queryKey: PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid),
          });
          // Invalidation alone only refetches *active* queries, and useEntries
          // opts out of refetchOnMount/refetchOnWindowFocus — so an invalidated
          // unread feed that isn't currently mounted would be served verbatim
          // from cache the next time the user opens it. Drop inactive unread
          // caches outright; the mounted one (if any) refetches via the
          // invalidation below.
          const isUnreadFeedQuery = ({ queryKey }: { queryKey: QueryKey }) =>
            (queryKey[0] === "entries" ||
              queryKey[0] === "aggregateEntries") &&
            queryKey[1] === viewerDid &&
            queryKey[queryKey.length - 1] === "unread";
          queryClient.removeQueries({
            predicate: isUnreadFeedQuery,
            type: "inactive",
          });
          void queryClient.invalidateQueries({ predicate: isUnreadFeedQuery });
        })
        .catch(() => {
          for (const [queryKey, snapshot] of cacheSnapshots) {
            queryClient.setQueryData(queryKey as QueryKey, snapshot);
          }
          markEntriesUnread(newlyRead, { publications });
          if (previouslyRead.length > 0) {
            markEntriesRead(previouslyRead, {
              publications,
              syncToAppView: false,
            });
          }
        });
    } else if (scopes.length > 0) {
      for (const [queryKey, snapshot] of cacheSnapshots) {
        queryClient.setQueryData(queryKey as QueryKey, snapshot);
      }
      markEntriesUnread(newlyRead, { publications });
      if (previouslyRead.length > 0) {
        markEntriesRead(previouslyRead, {
          publications,
          syncToAppView: false,
        });
      }
    }
  }, [
    markEntriesRead,
    cachedEntryIds,
    publications,
    getOAuthSession,
    options?.gatewayScopes,
    isEntryRead,
    markEntriesUnread,
    queryClient,
    viewerDid,
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
