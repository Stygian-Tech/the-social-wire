"use client";

import { useCallback, useLayoutEffect, useMemo, useRef } from "react";
import { useQueryClient, type InfiniteData, type QueryKey } from "@tanstack/react-query";

import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useAuth } from "@/hooks/useAuth";
import type { EntriesPage } from "@/hooks/useEntries";
import { applyUnreadCountsEvent } from "@/lib/bootstrapStreamState";
import { fetchReadAgeOptions, markReadBefore } from "@/lib/feedReadAgeClient";
import type {
  GatewayMarkAllReadScope,
  PublicationSidebarProjection,
} from "@/lib/publicationProjectionClient";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";

export function useFeedReadAgeActions(scope: GatewayMarkAllReadScope | null) {
  const queryClient = useQueryClient();
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const { markEntriesRead } = useReadRoute();
  const viewerDid = session?.did;
  const scopeKey = JSON.stringify(scope);
  const context = useMemo(
    () => ({ viewerDid, scopeKey, oauthSessionReloadSeq }),
    [viewerDid, scopeKey, oauthSessionReloadSeq]
  );
  const activeContext = useRef<typeof context | null>(context);
  useLayoutEffect(() => {
    activeContext.current = context;
    return () => {
      activeContext.current = null;
    };
  }, [context]);

  const beginAction = useCallback(() => {
    const oauth = getOAuthSession();
    if (!scope || !viewerDid || !oauth || oauth.did !== viewerDid) {
      throw new Error("Sign in and select a feed to mark older stories as read.");
    }
    const assertCurrent = () => {
      if (activeContext.current !== context || getOAuthSession() !== oauth) {
        throw new Error("The account or feed changed. Try again.");
      }
    };
    assertCurrent();
    return { oauth, scope, viewerDid, assertCurrent };
  }, [context, getOAuthSession, scope, viewerDid]);

  const loadOptions = useCallback(async () => {
    const action = beginAction();
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const response = await fetchReadAgeOptions(action.oauth, action.scope, timeZone);
    action.assertCurrent();
    return response.options;
  }, [beginAction]);

  const markBefore = useCallback(async (before: string) => {
    const action = beginAction();
    const confirmation = await markReadBefore(action.oauth, action.scope, before);
    action.assertCurrent();
    const isViewerFeedQuery = ({ queryKey }: { queryKey: QueryKey }) =>
      (queryKey[0] === "entries" || queryKey[0] === "aggregateEntries") &&
      queryKey[1] === action.viewerDid;

    // A pre-mutation request must not overwrite the confirmed read flags.
    await queryClient.cancelQueries({ predicate: isViewerFeedQuery });
    action.assertCurrent();
    const confirmedIds = new Set(confirmation.entryIds);
    if (confirmedIds.size > 0) {
      markEntriesRead([...confirmedIds], { syncToAppView: false });
      queryClient.setQueriesData<InfiniteData<EntriesPage>>(
        { predicate: isViewerFeedQuery },
        (current) => current ? {
          ...current,
          pages: current.pages.map((page) => ({
            ...page,
            entries: page.entries.map((entry) =>
              confirmedIds.has(entry.entryId) ? { ...entry, isRead: true } : entry
            ),
          })),
        } : current
      );
    }

    const sidebarKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(action.viewerDid);
    // Empty counts mean the recount was unavailable, not that the feed is empty.
    const countKeys = Object.keys(confirmation.unreadCounts);
    if (countKeys.length > 0) {
      queryClient.setQueryData<PublicationSidebarProjection>(sidebarKey, (current) =>
        current ? applyUnreadCountsEvent(current, confirmation.unreadCounts, {
          replacePublicationIds: countKeys,
          accuracy: "exact",
          countedAt: confirmation.readAt,
        }) : current
      );
    }
    void queryClient.invalidateQueries({ queryKey: sidebarKey });
    const isUnreadFeedQuery = (query: { queryKey: QueryKey }) =>
      isViewerFeedQuery(query) && query.queryKey.at(-1) === "unread";
    // Inactive feeds opt out of refetch-on-mount, so discard stale unread pages.
    queryClient.removeQueries({ predicate: isUnreadFeedQuery, type: "inactive" });
    // Restart every active feed request cancelled above, including an initial All load.
    void queryClient.invalidateQueries({ predicate: isViewerFeedQuery });
  }, [beginAction, markEntriesRead, queryClient]);

  return { loadOptions, markBefore };
}
