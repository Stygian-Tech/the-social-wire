"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useQueryClient, type InfiniteData } from "@tanstack/react-query";

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
  const pending = useRef(false);
  const [isMarkingRead, setIsMarkingRead] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const owner = useRef(viewerDid);
  useEffect(() => { owner.current = viewerDid; }, [viewerDid]);

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
    // A ref also guards two clicks before React paints the disabled state.
    if (pending.current) return false;
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
    pending.current = true;
    setIsMarkingRead(true);
    setError(null);
    try {
      // Settle every scope before allowing a retry; a rejected Promise.all can
      // otherwise leave old mutations running behind the next attempt.
      const results = await Promise.allSettled(scopes.map((scope) => pdsReadStateEnabled()
        ? markAllReadOnGateway(oauth, scope, selectedEntryIds.slice(0, 1000))
        : markAllReadOnGateway(oauth, scope)));
      if (owner.current !== viewerDid || getOAuthSession() !== oauth) return false;
      const confirmations = results.flatMap(result => result.status === "fulfilled" ? [result.value] : []);
      const failed = results.some(result => result.status === "rejected");
      // Do not roll back server mutations with per-entry unread writes or restore
      // old query snapshots over articles fetched while the request was running.
      if (failed) {
        void invalidateConfirmedReadStateQueries(queryClient, viewerDid);
        setError("Some stories could not be marked as read. Please try again.");
        return false;
      }
      if (confirmations.some(confirmation => confirmation.pendingSync)) return true;

      const selectedIds = new Set(selectedEntryIds);
      markEntriesRead(selectedEntryIds, { publications, syncToAppView: false });
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
        ...confirmations.flatMap(confirmation => confirmation.boundaries.map(boundary => boundary.publicationId)),
        ...Object.keys(confirmedCounts),
      ])];
      const confirmedAt = confirmations.map(confirmation => confirmation.confirmedAt).filter(Boolean).sort().at(-1);
      queryClient.setQueryData<PublicationSidebarProjection>(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(viewerDid), current => current
        ? applyUnreadCountsEvent(current, confirmedCounts, { replacePublicationIds, accuracy: "exact", countedAt: confirmedAt })
        : current);
      // Newly fetched rows need authoritative read state, including All feeds.
      // The server freezes membership using created_at, which publishedAt cannot
      // reconstruct; never mark every row arriving mid-flight locally read.
      void invalidateConfirmedReadStateQueries(queryClient, viewerDid);
      return true;
    } catch {
      if (owner.current === viewerDid) setError("Stories could not be marked as read. Please try again.");
      return false;
    } finally {
      pending.current = false;
      setIsMarkingRead(false);
    }
  }, [markEntriesRead, publications, getOAuthSession, options?.gatewayScopes, queryClient, viewerDid]);

  const applyMarkAllUnread = useCallback(() => {
    if (!pending.current) markEntriesUnread(cachedEntryIds, { publications });
  }, [markEntriesUnread, cachedEntryIds, publications]);

  return { cachedEntryIds, bulkDisabled, isMarkingRead, error, applyMarkAllRead, applyMarkAllUnread };
}
