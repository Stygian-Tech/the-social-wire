"use client";

import { useMutation, useQuery, useQueryClient, useIsRestoring } from "@tanstack/react-query";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import { useFolders } from "@/hooks/useFolders";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import { consumeBootstrapStream } from "@/lib/bootstrapStreamClient";
import {
  markBootstrapPerf,
  resetBootstrapPerf,
} from "@/lib/bootstrapStreamPerf";
import {
  applyBootstrapStreamEvent,
  applyUnreadCountsEvent,
  writeStreamedEntriesPage,
} from "@/lib/bootstrapStreamState";
import { prefetchCachedImages } from "@/lib/imageBlobCache";
import {
  COLLECTION_PUB_PREFS,
  type PublicationPrefsRecord,
  type RepoRecord,
} from "@/lib/pdsClient";
import {
  refreshPublicationSidebar,
  sidebarRowToDiscoveredPublication,
  unreadCountsMapFromProjection,
  type PublicationAppViewScope,
  type PublicationSidebarProjection,
  type SidebarPublicationRow,
} from "@/lib/publicationProjectionClient";
import { fetchAppViewUnreadCounts } from "@/lib/thinAppViewClient";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import { queueBootstrapFeedRefresh } from "@/hooks/useProactiveFeedRefresh";

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

/** Gateway bootstrap stream for subscribed/following lists and `/me/publications`. */
function sidebarListShowsSkeleton(args: {
  hasSidebarSnapshot: boolean;
  isRestoring: boolean;
  sidebarFetching: boolean;
  itemCount: number;
}): boolean {
  return (
    !args.hasSidebarSnapshot &&
    !args.isRestoring &&
    args.sidebarFetching &&
    args.itemCount === 0
  );
}

export function usePublicationSidebarData() {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const qc = useQueryClient();
  const isRestoring = useIsRestoring();
  const did = session?.did ?? "";
  const [streamSelectedPublicationId, setStreamSelectedPublicationId] = useState<
    string | null
  >(null);
  const [sidebarFetching, setSidebarFetching] = useState(false);
  const [folderPublicationsLoading, setFolderPublicationsLoading] = useState(false);
  const [projectionError, setProjectionError] = useState<Error | null>(null);
  const streamGenerationRef = useRef(0);
  const pendingAutoSelectPublicationIdRef = useRef<string | null>(null);
  const bootstrapFeedPublicationIdRef = useRef<string | null>(null);

  const cachedProjection = useQuery({
    queryKey: PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
    enabled: Boolean(did),
    staleTime: Infinity,
    gcTime: Infinity,
    refetchOnMount: false,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    queryFn: () =>
      qc.getQueryData<PublicationSidebarProjection>(
        PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did)
      ),
  }).data;

  const [streamProjection, setStreamProjection] = useState<
    PublicationSidebarProjection | undefined
  >(undefined);
  const [streamOwnerDid, setStreamOwnerDid] = useState(did);

  if (did !== streamOwnerDid) {
    setStreamOwnerDid(did);
    setStreamProjection(undefined);
    setStreamSelectedPublicationId(null);
    setSidebarFetching(false);
    setFolderPublicationsLoading(false);
    setProjectionError(null);
  }

  const mergedProjection = streamProjection ?? cachedProjection;

  const runBootstrapStream = useCallback(
    async (controller: AbortController) => {
      const oauth = getOAuthSession();
      if (!oauth || !did) return;

      resetBootstrapPerf();
      const hadSidebarSnapshot = Boolean(
        qc.getQueryData<PublicationSidebarProjection>(
          PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did)
        )
      );
      if (hadSidebarSnapshot) {
        markBootstrapPerf("cachedSidebarPaint");
      }

      const generation = ++streamGenerationRef.current;
      pendingAutoSelectPublicationIdRef.current = null;
      bootstrapFeedPublicationIdRef.current = null;

      setSidebarFetching(true);
      setProjectionError(null);
      setFolderPublicationsLoading(!hadSidebarSnapshot);

      try {
        await consumeBootstrapStream({
          oauthSession: oauth,
          signal: controller.signal,
          handlers: {
            onEvent: (event) => {
              if (generation !== streamGenerationRef.current) return;

              if (event.kind === "sidebarPriority") {
                markBootstrapPerf("sidebarPriority");
              }
              if (event.kind === "unreadCounts") {
                markBootstrapPerf("unreadCounts");
              }
              if (event.kind === "entriesPage") {
                markBootstrapPerf("entriesPage");
              }
              if (event.kind === "sidebarFolders") {
                markBootstrapPerf("sidebarFolders");
              }
              if (event.kind === "done") {
                markBootstrapPerf("done");
              }

              if (event.kind === "sidebarPriority" && !hadSidebarSnapshot) {
                setFolderPublicationsLoading(true);
              }
              if (event.kind === "sidebarFolders") {
                setFolderPublicationsLoading(false);
              }
              if (event.kind === "selectedPublication") {
                pendingAutoSelectPublicationIdRef.current =
                  event.payload.publicationId;
                bootstrapFeedPublicationIdRef.current =
                  event.payload.publicationId;
              }
              if (event.kind === "entriesPage") {
                writeStreamedEntriesPage(qc, event.payload);
                bootstrapFeedPublicationIdRef.current =
                  event.payload.publicationId;
                if (
                  pendingAutoSelectPublicationIdRef.current ===
                  event.payload.publicationId
                ) {
                  setStreamSelectedPublicationId(event.payload.publicationId);
                  pendingAutoSelectPublicationIdRef.current = null;
                }
              }
              if (event.kind === "done") {
                if (pendingAutoSelectPublicationIdRef.current) {
                  setStreamSelectedPublicationId(
                    pendingAutoSelectPublicationIdRef.current
                  );
                  bootstrapFeedPublicationIdRef.current =
                    bootstrapFeedPublicationIdRef.current ??
                    pendingAutoSelectPublicationIdRef.current;
                  pendingAutoSelectPublicationIdRef.current = null;
                }
                if (bootstrapFeedPublicationIdRef.current) {
                  queueBootstrapFeedRefresh({
                    queryClient: qc,
                    publicationKey: normalizeAtRepoParam(
                      bootstrapFeedPublicationIdRef.current
                    ),
                    oauthSession: oauth,
                    viewerDid: did,
                  });
                }
              }

              setStreamProjection((currentStream) => {
                const baseline =
                  qc.getQueryData<PublicationSidebarProjection>(
                    PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did)
                  ) ?? currentStream;
                const applied = applyBootstrapStreamEvent({
                  projection: baseline,
                  event,
                });
                if (applied.streamError) {
                  setProjectionError(new Error(applied.streamError));
                }
                if (applied.projection) {
                  qc.setQueryData(
                    PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
                    applied.projection
                  );
                  if (event.kind === "done") {
                    return undefined;
                  }
                  return applied.projection;
                }
                return currentStream;
              });
            },
            onError: (error) => {
              if (generation !== streamGenerationRef.current) return;
              setProjectionError(error);
            },
          },
        });
      } catch (error) {
        if (generation !== streamGenerationRef.current) return;
        if (!(error instanceof DOMException && error.name === "AbortError")) {
          setProjectionError(
            error instanceof Error ? error : new Error(String(error))
          );
        }
      } finally {
        if (generation === streamGenerationRef.current) {
          setSidebarFetching(false);
          setFolderPublicationsLoading(false);
        }
      }
    },
    [did, getOAuthSession, qc]
  );

  useEffect(() => {
    if (!session) return;
    const oauth = getOAuthSession();
    if (!oauth) return;
    const controller = new AbortController();
    queueMicrotask(() => {
      void runBootstrapStream(controller);
    });
    return () => {
      controller.abort();
      streamGenerationRef.current += 1;
    };
  }, [session, oauthSessionReloadSeq, runBootstrapStream, getOAuthSession]);

  useEffect(() => {
    if (!mergedProjection) return;
    prefetchCachedImages(
      mergedProjection.allPublicationRows.flatMap((row) => [
        row.iconUrl,
        row.avatarUrl,
      ])
    );
  }, [mergedProjection]);

  const hasSidebarSnapshot = mergedProjection != null;
  const sidebarListsLoading =
    !hasSidebarSnapshot && !isRestoring && sidebarFetching;

  const projectionState = useMemo(() => {
    if (!mergedProjection) return null;
    return projectionToSidebarState(mergedProjection);
  }, [mergedProjection]);

  // Prefer React Query cache for unread badges so optimistic mark-all-read updates
  // are visible even while in-memory streamProjection is still active.
  const unreadCountsByPublicationId = useMemo(
    () =>
      unreadCountsMapFromProjection(cachedProjection ?? mergedProjection),
    [cachedProjection, mergedProjection]
  );

  const folders = projectionState?.folders ?? [];
  const unfolderedPubs = projectionState?.unfolderedPubs ?? [];
  const followingTabPublications =
    projectionState?.followingTabPublications ?? [];

  const foldersListLoading = sidebarListShowsSkeleton({
    hasSidebarSnapshot,
    isRestoring,
    sidebarFetching,
    itemCount: folders.length,
  });
  const subscribedPublicationsLoading = sidebarListShowsSkeleton({
    hasSidebarSnapshot,
    isRestoring,
    sidebarFetching,
    itemCount: unfolderedPubs.length,
  });
  const followingPublicationsLoading = sidebarListShowsSkeleton({
    hasSidebarSnapshot,
    isRestoring,
    sidebarFetching,
    itemCount: followingTabPublications.length,
  });
  const folderPublicationsListLoading =
    !hasSidebarSnapshot && !isRestoring && folderPublicationsLoading;

  const refresh = useMutation({
    mutationFn: async () => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error("OAuth session required");
      const projection = await refreshPublicationSidebar(oauth);
      qc.setQueryData(PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did), projection);
      setStreamProjection(undefined);
      const controller = new AbortController();
      await runBootstrapStream(controller);
    },
  });

  const refreshUnreadCountsFromAppView = useCallback(async () => {
    const oauth = getOAuthSession();
    if (!oauth || !did) return;

    const projection = qc.getQueryData<PublicationSidebarProjection>(
      PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did)
    );
    if (!projection) return;

    const publicationIds = [
      ...new Set(projection.allPublicationRows.map((row) => row.publicationId)),
    ];
    if (publicationIds.length === 0) return;

    try {
      const counts = await fetchAppViewUnreadCounts(oauth, publicationIds);
      qc.setQueryData<PublicationSidebarProjection>(
        PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
        (current) =>
          current
            ? applyUnreadCountsEvent(current, counts, {
                replacePublicationIds: publicationIds,
              })
            : current
      );
    } catch {
      /* best-effort cross-client sync */
    }
  }, [did, getOAuthSession, qc]);

  return {
    folders,
    foldersLoading: foldersListLoading,
    foldersListLoading,
    prefsMap: projectionState?.prefsMap ?? new Map(),
    allPublicationRows: projectionState?.allPublicationRows ?? [],
    folderMap: projectionState?.folderMap ?? new Map(),
    myPublications: projectionState?.myPublications ?? [],
    unfolderedPubs,
    followingTabPublications,
    pubsLoading: subscribedPublicationsLoading,
    subscriptionsBlockLoading: subscribedPublicationsLoading,
    subscribedPublicationsLoading,
    followingPublicationsLoading,
    sidebarListsLoading,
    folderPublicationsLoading: folderPublicationsListLoading,
    hasSidebarSnapshot,
    sidebarFetching,
    refresh,
    refreshUnreadCountsFromAppView,
    viewerDid: session?.did,
    publicationSidebarProjection: mergedProjection,
    sidebarRowsById: projectionState?.sidebarRowsById,
    unreadCountsByPublicationId,
    unreadCountsLoading: false,
    projectionError,
    streamSelectedPublicationId,
  };
}

export type { SidebarPublicationRow, PublicationAppViewScope };
