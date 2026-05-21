"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useFolders } from "@/hooks/useFolders";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import {
  COLLECTION_PUB_PREFS,
  type PublicationPrefsRecord,
  type RepoRecord,
} from "@/lib/pdsClient";
import {
  fetchPublicationSidebar,
  maybeEnrollProjectionAuthors,
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

/** Gateway-only sidebar projection for subscribed/following lists and `/me/publications`. */
export function usePublicationSidebarData() {
  const { session, getOAuthSession } = useAuth();
  const qc = useQueryClient();

  const projectionQuery = useQuery({
    queryKey: PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(session?.did ?? ""),
    queryFn: async ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const projection = await fetchPublicationSidebar(oauth, signal);
      maybeEnrollProjectionAuthors(oauth, projection.enrollAuthorDids);
      return projection;
    },
    enabled: !!session,
    staleTime: 6 * 60_000,
    retry: 1,
  });

  const projectionState = useMemo(() => {
    if (!projectionQuery.data) return null;
    return projectionToSidebarState(projectionQuery.data);
  }, [projectionQuery.data]);

  const publicationIdsForUnread = useMemo(
    () => projectionState?.allPublicationRows.map((p) => p.publicationId) ?? [],
    [projectionState?.allPublicationRows]
  );

  const unreadCountsQuery = useQuery({
    queryKey: [
      "appviewUnreadCounts",
      session?.did ?? "",
      publicationIdsForUnread.join("\x1e"),
    ] as const,
    queryFn: async ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      return fetchAppViewUnreadCounts(oauth, publicationIdsForUnread, signal);
    },
    enabled:
      !!session &&
      publicationIdsForUnread.length > 0 &&
      projectionState != null &&
      projectionState.unreadCountsByPublicationId.size === 0,
    staleTime: 60_000,
    retry: 1,
  });

  const unreadCountsByPublicationId = useMemo(() => {
    if (!projectionState) return new Map<string, number>();
    if (projectionState.unreadCountsByPublicationId.size > 0) {
      return projectionState.unreadCountsByPublicationId;
    }
    const fromApi = unreadCountsQuery.data;
    if (!fromApi) return projectionState.unreadCountsByPublicationId;
    const map = new Map<string, number>();
    for (const [publicationId, count] of Object.entries(fromApi)) {
      if (count > 0) map.set(publicationId, count);
    }
    return map;
  }, [projectionState, unreadCountsQuery.data]);

  const refresh = useMutation({
    mutationFn: async () => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const projection = await refreshPublicationSidebar(oauth);
      qc.setQueryData(
        PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(session?.did ?? ""),
        projection
      );
      maybeEnrollProjectionAuthors(oauth, projection.enrollAuthorDids);
      qc.invalidateQueries({
        queryKey: ["appviewUnreadCounts", session?.did ?? ""],
      });
    },
  });

  return {
    folders: projectionState?.folders ?? [],
    foldersLoading: projectionQuery.isLoading,
    prefsMap: projectionState?.prefsMap ?? new Map(),
    allPublicationRows: projectionState?.allPublicationRows ?? [],
    folderMap: projectionState?.folderMap ?? new Map(),
    myPublications: projectionState?.myPublications ?? [],
    unfolderedPubs: projectionState?.unfolderedPubs ?? [],
    followingTabPublications: projectionState?.followingTabPublications ?? [],
    pubsLoading: projectionQuery.isLoading,
    subscriptionsBlockLoading: projectionQuery.isLoading,
    sidebarListsLoading: projectionQuery.isLoading,
    refresh,
    viewerDid: session?.did,
    publicationSidebarProjection: projectionQuery.data,
    sidebarRowsById: projectionState?.sidebarRowsById,
    unreadCountsByPublicationId,
    projectionError: projectionQuery.error,
  };
}

export type { SidebarPublicationRow, PublicationAppViewScope };
