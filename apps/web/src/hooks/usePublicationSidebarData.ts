"use client";

import { useSidebarBootstrap, useSidebarProjection } from "@/contexts/PublicationSidebarContext";

export { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
export type { SidebarPublicationRow, PublicationAppViewScope } from "@/lib/publicationProjectionClient";

/**
 * Compatibility facade over {@link useSidebarProjection} and {@link useSidebarBootstrap}.
 * Requires {@link PublicationSidebarProvider} — does not start its own bootstrap stream.
 */
export function usePublicationSidebarData() {
  const projection = useSidebarProjection();
  const bootstrap = useSidebarBootstrap();

  return {
    ...projection,
    foldersLoading: bootstrap.foldersListLoading,
    foldersListLoading: bootstrap.foldersListLoading,
    pubsLoading: bootstrap.subscribedPublicationsLoading,
    subscriptionsBlockLoading: bootstrap.subscribedPublicationsLoading,
    subscribedPublicationsLoading: bootstrap.subscribedPublicationsLoading,
    followingPublicationsLoading: bootstrap.followingPublicationsLoading,
    sidebarListsLoading: bootstrap.sidebarListsLoading,
    folderPublicationsLoading: bootstrap.folderPublicationsListLoading,
    hasSidebarSnapshot: bootstrap.hasSidebarSnapshot,
    sidebarFetching: bootstrap.sidebarFetching,
    bootstrapStreamComplete: bootstrap.bootstrapStreamComplete,
    refresh: bootstrap.refresh,
    refreshUnreadCountsFromAppView: bootstrap.refreshUnreadCountsFromAppView,
    viewerDid: bootstrap.viewerDid,
    projectionError: bootstrap.projectionError,
    streamSelectedPublicationId: bootstrap.streamSelectedPublicationId,
  };
}
