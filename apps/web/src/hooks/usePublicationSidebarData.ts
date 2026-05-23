"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useMemo } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useFolders } from "@/hooks/useFolders";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import { prefetchCachedImages } from "@/lib/imageBlobCache";
import {
  COLLECTION_PUB_PREFS,
  type PublicationPrefsRecord,
  type RepoRecord,
} from "@/lib/pdsClient";
import {
  fetchPublicationSidebar,
  maybeEnrollProjectionAuthors,
  mergeSidebarProjections,
  refreshPublicationSidebar,
  sidebarRowToDiscoveredPublication,
  unreadCountsMapFromProjection,
  type PublicationAppViewScope,
  type PublicationSidebarProjection,
  type SidebarPublicationRow,
} from "@/lib/publicationProjectionClient";
import { fetchAppViewUnreadCounts } from "@/lib/thinAppViewClient";

export const PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY = (did: string) =>
  ["publicationSidebarProjection", did] as const;

function prefsRecordFromProjection(
  row: PublicationSidebarProjection["publicationPrefs"][number]
): RepoRecord<PublicationPrefsRecord> {
  const raw = row.value;
  const folderId =
    typeof raw.folderId === "string" ? raw.folderId : undefined;
  const sortOrder =
    typeof raw.sortOrder === "number" ? raw.sortOrder : undefined;
  const hidden = typeof raw.hidden === "boolean" ? raw.hidden : undefined;
  const createdAt =
    typeof raw.createdAt === "string"
      ? raw.createdAt
      : new Date().toISOString();

  return {
    uri: row.uri,
    cid: typeof raw.cid === "string" ? raw.cid : "",
    value: {
      $type: COLLECTION_PUB_PREFS,
      publicationId: row.publicationId,
      folderId,
      sortOrder,
      hidden,
      createdAt,
    },
  };
}

function projectionToSidebarState(projection: PublicationSidebarProjection) {
  const prefsMap = new Map(
    projection.publicationPrefs.map((p) => [
      p.publicationId,
      prefsRecordFromProjection(p),
    ] as const)
  );

  const folderMap = new Map<string, DiscoveredPublication[]>();

  if (projection.folderSections?.length) {
    for (const section of projection.folderSections) {
      folderMap.set(
        section.folderRkey,
        section.publications.map(sidebarRowToDiscoveredPublication)
      );
    }
  } else {
    const myIds = new Set(
      projection.myPublications.map((m) => m.publicationId)
    );
    const followingIds = new Set(
      projection.followingTabPublications.map((f) => f.publicationId)
    );

    for (const row of projection.allPublicationRows) {
      const pub = sidebarRowToDiscoveredPublication(row);
      if (myIds.has(pub.publicationId) || followingIds.has(pub.publicationId)) {
        continue;
      }
      const pref = prefsMap.get(pub.publicationId);
      const folderId = pref?.value.folderId;
      if (!folderId) continue;
      const list = folderMap.get(folderId) ?? [];
      list.push(pub);
      folderMap.set(folderId, list);
    }
  }

  const subscribed = projection.subscribedUnfoldered.map(
    sidebarRowToDiscoveredPublication
  );
  const myPublications = projection.myPublications.map(
    sidebarRowToDiscoveredPublication
  );

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
    unreadCountsByPublicationId: unreadCountsMapFromProjection(projection),
  };
}

function publicationIdsFromProjection(
  projection: PublicationSidebarProjection | undefined
): string[] {
  if (!projection) return [];
  return projection.allPublicationRows.map((row) => row.publicationId);
}

/** Gateway-only sidebar projection for subscribed/following lists and `/me/publications`. */
export function usePublicationSidebarData() {
  const { session, getOAuthSession } = useAuth();
  const qc = useQueryClient();
  const did = session?.did ?? "";

  const priorityQuery = useQuery({
    queryKey: [...PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did), "priority"] as const,
    queryFn: async ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const projection = await fetchPublicationSidebar(oauth, {
        phase: "priority",
        signal,
      });
      maybeEnrollProjectionAuthors(oauth, projection.enrollAuthorDids);
      return projection;
    },
    enabled: !!session,
    staleTime: 6 * 60_000,
    gcTime: 1000 * 60 * 60 * 24 * 7,
    retry: 1,
    refetchOnWindowFocus: false,
  });

  const foldersQuery = useQuery({
    queryKey: [
      ...PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
      "folderPublications",
    ] as const,
    queryFn: async ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      return fetchPublicationSidebar(oauth, {
        phase: "folderPublications",
        signal,
      });
    },
    enabled: !!session && priorityQuery.isSuccess,
    staleTime: 6 * 60_000,
    gcTime: 1000 * 60 * 60 * 24 * 7,
    retry: 1,
    refetchOnWindowFocus: false,
  });

  const mergedProjection = useMemo(() => {
    if (!priorityQuery.data) return undefined;
    return mergeSidebarProjections(priorityQuery.data, foldersQuery.data);
  }, [priorityQuery.data, foldersQuery.data]);

  useEffect(() => {
    if (!mergedProjection || !did) return;
    qc.setQueryData(
      PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
      mergedProjection
    );
  }, [mergedProjection, did, qc]);

  useEffect(() => {
    if (!mergedProjection) return;
    prefetchCachedImages(
      mergedProjection.allPublicationRows.flatMap((row) => [
        row.iconUrl,
        row.avatarUrl,
      ])
    );
  }, [mergedProjection]);

  const hasCachedProjection = priorityQuery.data != null;
  const sidebarFetching =
    (priorityQuery.isFetching && !priorityQuery.isPending) ||
    foldersQuery.isFetching;

  const projectionState = useMemo(() => {
    if (!mergedProjection) return null;
    return projectionToSidebarState(mergedProjection);
  }, [mergedProjection]);

  const priorityPublicationIds = useMemo(
    () => publicationIdsFromProjection(priorityQuery.data),
    [priorityQuery.data]
  );

  const folderPublicationIds = useMemo(() => {
    if (!foldersQuery.data) return [];
    return publicationIdsFromProjection(foldersQuery.data);
  }, [foldersQuery.data]);

  const priorityUnreadQuery = useQuery({
    queryKey: [
      "appviewUnreadCounts",
      did,
      "priority",
      priorityPublicationIds.join("\x1e"),
    ] as const,
    queryFn: async ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      return fetchAppViewUnreadCounts(oauth, priorityPublicationIds, signal);
    },
    enabled: !!session && priorityPublicationIds.length > 0,
    staleTime: 60_000,
    retry: 1,
  });

  const folderUnreadQuery = useQuery({
    queryKey: [
      "appviewUnreadCounts",
      did,
      "folders",
      folderPublicationIds.join("\x1e"),
    ] as const,
    queryFn: async ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      return fetchAppViewUnreadCounts(oauth, folderPublicationIds, signal);
    },
    enabled: !!session && folderPublicationIds.length > 0,
    staleTime: 60_000,
    retry: 1,
  });

  const unreadCountsByPublicationId = useMemo(() => {
    const map = new Map<string, number>();
    if (projectionState?.unreadCountsByPublicationId.size) {
      for (const [id, count] of projectionState.unreadCountsByPublicationId) {
        if (count > 0) map.set(id, count);
      }
    }
    for (const source of [priorityUnreadQuery.data, folderUnreadQuery.data]) {
      if (!source) continue;
      for (const [publicationId, count] of Object.entries(source)) {
        if (count > 0) map.set(publicationId, count);
      }
    }
    return map;
  }, [
    projectionState?.unreadCountsByPublicationId,
    priorityUnreadQuery.data,
    folderUnreadQuery.data,
  ]);

  const refresh = useMutation({
    mutationFn: async () => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const projection = await refreshPublicationSidebar(oauth);
      qc.setQueryData(
        [...PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did), "priority"],
        projection
      );
      qc.setQueryData(
        [...PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did), "folderPublications"],
        undefined
      );
      maybeEnrollProjectionAuthors(oauth, projection.enrollAuthorDids);
      qc.invalidateQueries({ queryKey: ["appviewUnreadCounts", did] });
      void qc.fetchQuery({
        queryKey: [
          ...PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
          "folderPublications",
        ],
        queryFn: () =>
          fetchPublicationSidebar(oauth, { phase: "folderPublications" }),
      });
    },
  });

  return {
    folders: projectionState?.folders ?? [],
    foldersLoading: priorityQuery.isPending && !hasCachedProjection,
    prefsMap: projectionState?.prefsMap ?? new Map(),
    allPublicationRows: projectionState?.allPublicationRows ?? [],
    folderMap: projectionState?.folderMap ?? new Map(),
    myPublications: projectionState?.myPublications ?? [],
    unfolderedPubs: projectionState?.unfolderedPubs ?? [],
    followingTabPublications: projectionState?.followingTabPublications ?? [],
    pubsLoading: priorityQuery.isPending && !hasCachedProjection,
    subscriptionsBlockLoading: priorityQuery.isPending && !hasCachedProjection,
    sidebarListsLoading: priorityQuery.isPending && !hasCachedProjection,
    folderPublicationsLoading:
      priorityQuery.isSuccess &&
      (foldersQuery.isPending || foldersQuery.isFetching),
    sidebarFetching,
    refresh,
    viewerDid: session?.did,
    publicationSidebarProjection: mergedProjection,
    sidebarRowsById: projectionState?.sidebarRowsById,
    unreadCountsByPublicationId,
    unreadCountsLoading:
      priorityUnreadQuery.isPending || folderUnreadQuery.isPending,
    projectionError: priorityQuery.error ?? foldersQuery.error,
  };
}

export type { SidebarPublicationRow, PublicationAppViewScope };
