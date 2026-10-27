"use client";

import { useCallback, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { useQueryClient, type InfiniteData } from "@tanstack/react-query";

import { acquireBulkRead, bulkReadPending, readEntryMutationRevision, readFeedRefreshRevision, recordReadEntryMutations, releaseBulkRead, subscribeBulkReadPending } from "@/lib/feedRefreshCoordinator";
import { pdsReadStateEnabled } from "@/lib/pdsReadStateRuntime";
import { useAuth } from "@/hooks/useAuth";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useEntriesCacheEpoch } from "@/hooks/useEntriesCacheEpoch";
import {
  markAllReadOnGateway,
  type GatewayMarkAllReadScope,
  type PublicationSidebarProjection,
} from "@/lib/publicationProjectionClient";
import { distinctCachedEntryIdsForPublications } from "@/lib/unreadCounts";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import { applyUnreadCountsEvent } from "@/lib/bootstrapStreamState";
import { invalidateConfirmedReadStateQueries } from "@/lib/pendingReadStateOverlay";
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
  const { markEntriesRead, markEntriesUnread } = useReadRoute();
  const oauthSession = getOAuthSession();
  const isMarkingRead = useSyncExternalStore(
    useCallback(listener => subscribeBulkReadPending(queryClient, listener), [queryClient]),
    useCallback(() => bulkReadPending(queryClient, oauthSession), [queryClient, oauthSession]),
    () => false,
  );
  const [error, setError] = useState<string | null>(null);
  const owner = useRef<object | null>(null);
  useLayoutEffect(() => {
    const scope = {};
    owner.current = scope;
    return () => { if (owner.current === scope) owner.current = null; };
  }, [viewerDid, oauthSession]);

  const cachedEntryIds = useMemo(() => {
    void entriesEpoch;
    return viewerDid
      ? distinctCachedEntryIdsForPublications(queryClient, viewerDid, publications)
      : [];
  }, [queryClient, publications, entriesEpoch, viewerDid]);

  const bulkDisabled =
    isMarkingRead || (cachedEntryIds.length === 0 &&
    publications.length === 0 &&
    (options?.gatewayScopes?.length ?? 0) === 0);

  const applyMarkAllRead = useCallback(async (): Promise<boolean> => {
    const oauth = getOAuthSession();
    if (!oauth || !viewerDid) {
      setError("Sign in again to mark this feed as read.");
      return false;
    }
    const scopes = options?.gatewayScopes ?? publications.map((publication) => ({
      kind: "publication" as const,
      publicationId: publication.publicationId,
    }));
    if (scopes.length === 0) return false;
    // Read the live cache at the click, rather than the last throttled cache epoch.
    const selectedEntryIds = distinctCachedEntryIdsForPublications(queryClient, viewerDid, publications);
    const operation = acquireBulkRead(queryClient, oauth);
    if (!operation) return false;
    const scopeOwner = owner.current;
    const sameSession = () => owner.current === scopeOwner && scopeOwner !== null && getOAuthSession() === oauth;
    const revision = recordReadEntryMutations(queryClient, oauth, selectedEntryIds);
    const stillOwnsEntry = (entryId: string) => readEntryMutationRevision(queryClient, oauth, entryId) <= revision;
    const countsAreCurrent = () => readFeedRefreshRevision(queryClient, oauth) === revision;
    setError(null);
    try {
      // Settle every scope before allowing a retry; a rejected Promise.all can
      // otherwise leave old mutations running behind the next attempt.
      const results = await Promise.allSettled(scopes.map((scope) => pdsReadStateEnabled()
        ? markAllReadOnGateway(oauth, scope, selectedEntryIds.slice(0, 1000))
        : markAllReadOnGateway(oauth, scope)));
      if (!sameSession()) return false;
      const confirmations = results.flatMap(result => result.status === "fulfilled" ? [result.value] : []);
      const failed = results.some(result => result.status === "rejected");
      // Do not roll back server mutations with per-entry unread writes or restore
      // old query snapshots over articles fetched while the request was running.
      if (failed) {
        void invalidateConfirmedReadStateQueries(queryClient, viewerDid).catch(() => undefined);
        setError("Some stories could not be marked as read. Please try again.");
        return false;
      }
      if (confirmations.some(confirmation => confirmation.pendingSync)) return true;

      const ownedEntryIds = selectedEntryIds.filter(stillOwnsEntry);
      const selectedIds = new Set(ownedEntryIds);
      markEntriesRead(ownedEntryIds, { publications: countsAreCurrent() ? publications : undefined, syncToAppView: false });
      queryClient.setQueriesData<InfiniteData<EntriesPage>>({
        predicate: ({ queryKey }) =>
          (queryKey[0] === "entries" || queryKey[0] === "aggregateEntries") && queryKey[1] === viewerDid,
      }, current => current ? {
        ...current,
        pages: current.pages.map(page => ({
          ...page,
          entries: page.entries.map(entry => selectedIds.has(entry.entryId) ? { ...entry, isRead: true } : entry),
        })),
      } : current);

      const confirmedCounts = Object.assign({}, ...confirmations.map(confirmation => confirmation.unreadCounts ?? {})) as Record<string, number>;
      const replacePublicationIds = [...new Set([
        ...publications.map(publication => publication.publicationId),
        ...confirmations.flatMap(confirmation => (confirmation.boundaries ?? []).map(boundary => boundary.publicationId)),
        ...Object.keys(confirmedCounts),
      ])];
      const confirmedAt = confirmations.map(confirmation => confirmation.confirmedAt).filter(Boolean).sort().at(-1);
      if (countsAreCurrent()) queryClient.setQueryData<PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid), current => current
        ? applyUnreadCountsEvent(current, confirmedCounts, { replacePublicationIds, accuracy: "exact", countedAt: confirmedAt })
        : current);
      // Newly fetched rows need authoritative read state, including All feeds.
      // The server freezes membership using created_at, which publishedAt cannot
      // reconstruct; never mark every row arriving mid-flight locally read.
      void invalidateConfirmedReadStateQueries(queryClient, viewerDid).catch(() => undefined);
      return true;
    } catch {
      if (sameSession()) setError("Stories could not be marked as read. Please try again.");
      return false;
    } finally {
      releaseBulkRead(queryClient, oauth, operation);
    }
  }, [markEntriesRead, publications, getOAuthSession, options?.gatewayScopes, queryClient, viewerDid]);

  const applyMarkAllUnread = useCallback(() => {
    if (!bulkReadPending(queryClient, getOAuthSession())) markEntriesUnread(cachedEntryIds, { publications });
  }, [markEntriesUnread, cachedEntryIds, publications, queryClient, getOAuthSession]);

  return { cachedEntryIds, bulkDisabled, isMarkingRead, error, applyMarkAllRead, applyMarkAllUnread };
}
