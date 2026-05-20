"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useMemo } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useFolders } from "@/hooks/useFolders";
import {
  useDiscovery,
  useGraphSubscriptionPublications,
  usePublicationPrefs,
  usePublicationSubscriptions,
  useRefreshDiscovery,
  useSkyreaderFeedSubscriptions,
  skyreaderSubscriptionsToDiscoveredPublications,
} from "@/hooks/usePublications";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import { viewerOwnsDiscoveredPublication } from "@/lib/atprotoClient";
import {
  addPublicationSubscriptionLookupKeys,
  publicationSubscriptionMatchKeys,
} from "@/lib/publicationSubscriptionMatch";
import type { PublicationPrefsRecord, RepoRecord } from "@/lib/pdsClient";
import {
  fetchPublicationSidebar,
  isPublicationProjectionEnabled,
  maybeEnrollProjectionAuthors,
  refreshPublicationSidebar,
  sidebarRowToDiscoveredPublication,
  type PublicationAppViewScope,
  type PublicationSidebarProjection,
  type SidebarPublicationRow,
} from "@/lib/publicationProjectionClient";

export const PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY = (did: string) =>
  ["publicationSidebarProjection", did] as const;

function legacySidebarMerge(args: {
  folders: ReturnType<typeof useFolders>["data"];
  publications: DiscoveredPublication[];
  prefs: RepoRecord<PublicationPrefsRecord>[];
  subscriptions: RepoRecord<{ publication?: string }>[];
  skyreaderRecords: ReturnType<typeof useSkyreaderFeedSubscriptions>["data"];
  graphSubscriptionRows: DiscoveredPublication[];
  viewerDid: string | undefined;
}) {
  const {
    folders = [],
    publications = [],
    prefs = [],
    subscriptions = [],
    skyreaderRecords = [],
    graphSubscriptionRows = [],
    viewerDid,
  } = args;

  const rssPublicationRows = skyreaderSubscriptionsToDiscoveredPublications(
    skyreaderRecords ?? []
  );

  const prefsMap = new Map(
    prefs.map((p) => [p.value.publicationId, p] as const)
  );

  const visiblePubs = [...publications, ...graphSubscriptionRows];
  const allPublicationRows = [
    ...publications,
    ...rssPublicationRows,
    ...graphSubscriptionRows,
  ];

  const subscriptionPublicationKeys = new Set<string>();
  for (const subscription of subscriptions) {
    addPublicationSubscriptionLookupKeys(
      subscriptionPublicationKeys,
      subscription.value.publication
    );
  }

  const isSubscribedPublication = (pub: DiscoveredPublication) =>
    publicationSubscriptionMatchKeys(pub).some((key) =>
      subscriptionPublicationKeys.has(key)
    );

  const graphSubscribedPubs: DiscoveredPublication[] = [];
  const followOwnedUnsubscribedPubs: DiscoveredPublication[] = [];

  for (const pub of visiblePubs) {
    if (viewerOwnsDiscoveredPublication(pub, viewerDid)) {
      graphSubscribedPubs.push(pub);
    } else if (isSubscribedPublication(pub)) {
      graphSubscribedPubs.push(pub);
    } else {
      followOwnedUnsubscribedPubs.push(pub);
    }
  }

  const subscribedPubs: DiscoveredPublication[] = [...graphSubscribedPubs];
  const ids = new Set(graphSubscribedPubs.map((p) => p.publicationId));
  for (const r of rssPublicationRows) {
    if (!ids.has(r.publicationId)) {
      subscribedPubs.push(r);
      ids.add(r.publicationId);
    }
  }
  for (const r of graphSubscriptionRows) {
    if (!ids.has(r.publicationId)) {
      subscribedPubs.push(r);
      ids.add(r.publicationId);
    }
  }

  const folderMap = new Map<string, DiscoveredPublication[]>();
  const myPublications: DiscoveredPublication[] = [];
  const unfolderedPubs: DiscoveredPublication[] = [];

  for (const pub of subscribedPubs) {
    if (viewerOwnsDiscoveredPublication(pub, viewerDid)) {
      myPublications.push(pub);
      continue;
    }
    const pref = prefsMap.get(pub.publicationId);
    const folderId = pref?.value.folderId;
    if (folderId) {
      const list = folderMap.get(folderId) ?? [];
      list.push(pub);
      folderMap.set(folderId, list);
      continue;
    }
    unfolderedPubs.push(pub);
  }

  const myPublicationIds = new Set(myPublications.map((p) => p.publicationId));
  const followingTabPublications = followOwnedUnsubscribedPubs.filter(
    (pub) => !myPublicationIds.has(pub.publicationId)
  );

  return {
    folders,
    prefsMap,
    allPublicationRows,
    folderMap,
    myPublications,
    unfolderedPubs,
    followingTabPublications,
  };
}

function projectionToSidebarState(projection: PublicationSidebarProjection) {
  const prefsMap = new Map(
    projection.publicationPrefs.map((p) => [
      p.publicationId,
      {
        uri: p.uri,
        cid: undefined,
        value: p.value as PublicationPrefsRecord,
      } satisfies RepoRecord<PublicationPrefsRecord>,
    ])
  );

  const folderMap = new Map<string, DiscoveredPublication[]>();
  const subscribed = projection.subscribedUnfoldered.map(
    sidebarRowToDiscoveredPublication
  );
  const myPublications = projection.myPublications.map(
    sidebarRowToDiscoveredPublication
  );

  for (const row of projection.allPublicationRows) {
    const pub = sidebarRowToDiscoveredPublication(row);
    const pref = prefsMap.get(pub.publicationId);
    const folderId = pref?.value.folderId;
    if (!folderId) continue;
    if (projection.myPublications.some((m) => m.publicationId === pub.publicationId)) {
      continue;
    }
    const list = folderMap.get(folderId) ?? [];
    list.push(pub);
    folderMap.set(folderId, list);
  }

  return {
    folders: projection.folders as unknown as ReturnType<typeof useFolders>["data"],
    prefsMap,
    allPublicationRows: projection.allPublicationRows.map(
      sidebarRowToDiscoveredPublication
    ),
    sidebarRowsById: new Map(
      projection.allPublicationRows.map((r) => [r.publicationId, r] as const)
    ),
    folderMap,
    myPublications,
    unfolderedPubs: subscribed,
    followingTabPublications: projection.followingTabPublications.map(
      sidebarRowToDiscoveredPublication
    ),
    enrollAuthorDids: projection.enrollAuthorDids,
  };
}

/** Shared discovery/subscription derivation for sidebar + `/me/publications`. */
export function usePublicationSidebarData() {
  const { session, getOAuthSession } = useAuth();
  const qc = useQueryClient();
  const useProjection = isPublicationProjectionEnabled();

  const projectionQuery = useQuery({
    queryKey: PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(session?.did ?? ""),
    queryFn: async ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const projection = await fetchPublicationSidebar(oauth, signal);
      maybeEnrollProjectionAuthors(oauth, projection.enrollAuthorDids);
      return projection;
    },
    enabled: useProjection && !!session,
    staleTime: 6 * 60_000,
    retry: 1,
  });

  const { data: folders = [], isLoading: foldersLoading } = useFolders();
  const { data: publications = [], isLoading: pubsLoading } = useDiscovery();
  const { data: prefs = [] } = usePublicationPrefs();
  const { data: subscriptions = [], isLoading: subscriptionsLoading } =
    usePublicationSubscriptions();
  const { data: skyreaderRecords = [], isLoading: skyreaderSubsLoading } =
    useSkyreaderFeedSubscriptions();
  const refreshDiscovery = useRefreshDiscovery();

  const rssPublicationRows = useMemo(
    () => skyreaderSubscriptionsToDiscoveredPublications(skyreaderRecords),
    [skyreaderRecords]
  );

  const { data: graphSubscriptionRows = [], isLoading: graphSubsLoading } =
    useGraphSubscriptionPublications(subscriptions, [
      ...publications,
      ...rssPublicationRows,
    ]);

  const legacy = useMemo(
    () =>
      legacySidebarMerge({
        folders,
        publications,
        prefs,
        subscriptions,
        skyreaderRecords,
        graphSubscriptionRows,
        viewerDid: session?.did,
      }),
    [
      folders,
      publications,
      prefs,
      subscriptions,
      skyreaderRecords,
      graphSubscriptionRows,
      session?.did,
    ]
  );

  const projectionState = useMemo(() => {
    if (!projectionQuery.data) return null;
    return projectionToSidebarState(projectionQuery.data);
  }, [projectionQuery.data]);

  const useServerProjection =
    useProjection && projectionQuery.isSuccess && projectionState != null;

  const refresh = useCallback(async () => {
    if (useServerProjection) {
      const oauth = getOAuthSession();
      if (!oauth) return;
      const projection = await refreshPublicationSidebar(oauth);
      qc.setQueryData(
        PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(session?.did ?? ""),
        projection
      );
      maybeEnrollProjectionAuthors(oauth, projection.enrollAuthorDids);
      return;
    }
    await refreshDiscovery.mutateAsync();
  }, [
    useServerProjection,
    getOAuthSession,
    qc,
    session?.did,
    refreshDiscovery,
  ]);

  const subscriptionsBlockLoading = useServerProjection
    ? projectionQuery.isLoading
    : subscriptionsLoading || skyreaderSubsLoading || graphSubsLoading;

  const sidebarListsLoading = useServerProjection
    ? projectionQuery.isLoading
    : foldersLoading || pubsLoading || subscriptionsBlockLoading;

  return {
    folders: useServerProjection ? (projectionState?.folders ?? []) : folders,
    foldersLoading: useServerProjection ? false : foldersLoading,
    prefsMap: useServerProjection ? projectionState!.prefsMap : legacy.prefsMap,
    allPublicationRows: useServerProjection
      ? projectionState!.allPublicationRows
      : legacy.allPublicationRows,
    folderMap: useServerProjection ? projectionState!.folderMap : legacy.folderMap,
    myPublications: useServerProjection
      ? projectionState!.myPublications
      : legacy.myPublications,
    unfolderedPubs: useServerProjection
      ? projectionState!.unfolderedPubs
      : legacy.unfolderedPubs,
    followingTabPublications: useServerProjection
      ? projectionState!.followingTabPublications
      : legacy.followingTabPublications,
    pubsLoading: useServerProjection ? projectionQuery.isLoading : pubsLoading,
    subscriptionsBlockLoading,
    sidebarListsLoading,
    refresh,
    viewerDid: session?.did,
    publicationSidebarProjection: projectionQuery.data,
    sidebarRowsById: useServerProjection
      ? projectionState!.sidebarRowsById
      : undefined,
  };
}

export type { SidebarPublicationRow, PublicationAppViewScope };
