"use client";

import { useCallback, useMemo, useSyncExternalStore } from "react";
import {
  useQueryClient,
  type InfiniteData,
  type QueryKey,
} from "@tanstack/react-query";

import { acquireBulkRead, bulkReadPending, readEntryMutationRevision, readFeedRefreshRevision, recordReadEntryMutations, releaseBulkRead, subscribeBulkReadPending } from "@/lib/feedRefreshCoordinator";
import { invalidateConfirmedReadStateQueries } from "@/lib/pendingReadStateOverlay";
import { pdsReadStateEnabled } from "@/lib/pdsReadStateRuntime";
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
  const oauthSession = getOAuthSession();
  const pendingBulk = useSyncExternalStore(
    useCallback(listener => subscribeBulkReadPending(queryClient, listener), [queryClient]),
    useCallback(() => bulkReadPending(queryClient, oauthSession), [queryClient, oauthSession]),
    () => false,
  );
  const {
    markEntriesRead,
    markEntriesUnread,
    isEntryRead,
    pendingEntryReadState,
  } = useReadRoute();

  const cachedEntryIds = useMemo(() => {
    void entriesEpoch;
    return viewerDid
      ? distinctCachedEntryIdsForPublications(queryClient, viewerDid, publications)
      : [];
  }, [queryClient, publications, entriesEpoch, viewerDid]);

  const bulkDisabled = pendingBulk ||
    cachedEntryIds.length === 0 &&
    publications.length === 0 &&
    (options?.gatewayScopes?.length ?? 0) === 0;

  const applyMarkAllRead = useCallback(() => {
    const oauth = getOAuthSession();
    const scopes = options?.gatewayScopes ?? publications.map(publication => ({
      kind: "publication" as const, publicationId: publication.publicationId,
    }));
    const operation = oauth && scopes.length ? acquireBulkRead(queryClient, oauth) : null;
    if (oauth && scopes.length && !operation) return;
    const revision = oauth ? recordReadEntryMutations(queryClient, oauth, cachedEntryIds) : 0;
    const sameSession = () => getOAuthSession() === oauth;
    const stillOwnsEntry = (entryId: string) => sameSession() &&
      (!oauth || readEntryMutationRevision(queryClient, oauth, entryId) <= revision);
    const countsAreCurrent = () => sameSession() &&
      (!oauth || readFeedRefreshRevision(queryClient, oauth) === revision);
    const deferOptimism = pdsReadStateEnabled();
    const cacheSnapshots = queryClient.getQueriesData<InfiniteData<EntriesPage>>({
      predicate: ({ queryKey }) =>
        (queryKey[0] === "entries" || queryKey[0] === "aggregateEntries") && queryKey[1] === viewerDid,
    });
    const serverReadIds = new Set(cacheSnapshots.flatMap(([, data]) =>
      data?.pages.flatMap(page => page.entries.filter(entry => entry.isRead).map(entry => entry.entryId)) ?? []));
    const entryWasRead = (entryId: string) => pendingEntryReadState?.(entryId) ??
      (serverReadIds.has(entryId) || isEntryRead(entryId));
    const previouslyRead = cachedEntryIds.filter(entryWasRead);
    const newlyRead = cachedEntryIds.filter(entryId => !entryWasRead(entryId));
    if (!deferOptimism) markEntriesRead(cachedEntryIds, {
      publications,
      syncToAppView: false,
    });
    for (const [queryKey, data] of deferOptimism ? [] : cacheSnapshots) {
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
    const rollback = () => {
      if (deferOptimism || !sameSession()) return;
      const ownedIds = new Set(cachedEntryIds.filter(stillOwnsEntry));
      const countPublications = countsAreCurrent() ? publications : undefined;
      for (const [queryKey, snapshot] of cacheSnapshots) {
        const prior = new Map(snapshot?.pages.flatMap(page => page.entries.map(entry => [entry.entryId, entry] as const)) ?? []);
        queryClient.setQueryData<InfiniteData<EntriesPage>>(queryKey, current => current ? {
          ...current,
          pages: current.pages.map(page => ({ ...page, entries: page.entries.map(entry =>
            ownedIds.has(entry.entryId) && prior.has(entry.entryId) ? { ...entry, isRead: prior.get(entry.entryId)?.isRead } : entry) })),
        } : current);
      }
      markEntriesUnread(newlyRead.filter(entryId => ownedIds.has(entryId)), { publications: countPublications });
      const restoreRead = previouslyRead.filter(entryId => ownedIds.has(entryId));
      if (restoreRead.length) markEntriesRead(restoreRead, { syncToAppView: false });
    };
    if (oauth && scopes.length > 0) {
      void Promise.all(scopes.map((scope) => pdsReadStateEnabled()
        ? markAllReadOnGateway(oauth, scope, cachedEntryIds.slice(0, 1000)) : markAllReadOnGateway(oauth, scope)))
        .then((confirmations) => {
          if (!sameSession() || !viewerDid || confirmations.some(confirmation => confirmation.pendingSync)) return;
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
          if (countsAreCurrent()) queryClient.setQueryData<PublicationSidebarProjection>(
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
          ).filter(stillOwnsEntry);
          if (settledEntryIds.length > 0) {
            markEntriesRead(settledEntryIds, {
              publications: countsAreCurrent() ? publications : undefined,
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
          rollback();
          if (sameSession() && viewerDid) void invalidateConfirmedReadStateQueries(queryClient, viewerDid).catch(() => {});
        }).finally(() => {
          if (operation) releaseBulkRead(queryClient, oauth, operation);
        }).catch(() => {});
    } else if (scopes.length > 0) {
      rollback();
    }
  }, [
    markEntriesRead,
    cachedEntryIds,
    publications,
    getOAuthSession,
    options?.gatewayScopes,
    isEntryRead,
    pendingEntryReadState,
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
