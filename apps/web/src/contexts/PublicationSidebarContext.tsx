"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import {
  useMutation,
  useQuery,
  useQueryClient,
  useIsRestoring,
} from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { queueBootstrapFeedRefresh } from "@/hooks/useProactiveFeedRefresh";
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
import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import {
  refreshPublicationSidebar,
  unreadCountsMapFromProjection,
  type PublicationSidebarProjection,
} from "@/lib/publicationProjectionClient";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import {
  projectionToSidebarState,
  sidebarListShowsSkeleton,
  type SidebarProjectionState,
} from "@/lib/sidebarProjectionState";
import { fetchAppViewUnreadCounts } from "@/lib/thinAppViewClient";

export type SidebarBootstrapState = {
  streamSelectedPublicationId: string | null;
  sidebarFetching: boolean;
  bootstrapStreamComplete: boolean;
  folderPublicationsLoading: boolean;
  hasSidebarSnapshot: boolean;
  sidebarListsLoading: boolean;
  foldersListLoading: boolean;
  subscribedPublicationsLoading: boolean;
  followingPublicationsLoading: boolean;
  folderPublicationsListLoading: boolean;
  projectionError: Error | null;
  refresh: ReturnType<typeof useMutation<void, Error, void>>;
  refreshUnreadCountsFromAppView: () => Promise<void>;
  viewerDid: string | undefined;
};

type PublicationSidebarContextValue = {
  mergedProjection: PublicationSidebarProjection | undefined;
  cachedProjection: PublicationSidebarProjection | undefined;
  projectionState: SidebarProjectionState | null;
  unreadCountsByPublicationId: Map<string, number>;
  bootstrap: SidebarBootstrapState;
};

const PublicationSidebarContext =
  createContext<PublicationSidebarContextValue | null>(null);

export function PublicationSidebarProvider({ children }: { children: ReactNode }) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const qc = useQueryClient();
  const isRestoring = useIsRestoring();
  const did = session?.did ?? "";

  const [streamSelectedPublicationId, setStreamSelectedPublicationId] = useState<
    string | null
  >(null);
  const [sidebarFetching, setSidebarFetching] = useState(false);
  const [bootstrapStreamComplete, setBootstrapStreamComplete] = useState(false);
  const [folderPublicationsLoading, setFolderPublicationsLoading] =
    useState(false);
  const [projectionError, setProjectionError] = useState<Error | null>(null);
  const streamGenerationRef = useRef(0);
  const pendingAutoSelectPublicationIdRef = useRef<string | null>(null);
  const bootstrapFeedPublicationIdRef = useRef<string | null>(null);
  const bootstrapCompletedAtRef = useRef<number | null>(null);
  const unreadRefreshDebounceRef = useRef<ReturnType<typeof setTimeout> | null>(
    null
  );

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
      ) ?? null,
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
    setBootstrapStreamComplete(false);
    setFolderPublicationsLoading(false);
    setProjectionError(null);
    bootstrapCompletedAtRef.current = null;
  }

  const mergedProjection = streamProjection ?? cachedProjection ?? undefined;

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
      setBootstrapStreamComplete(false);
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
                setSidebarFetching(false);
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
                if (event.payload.entries.length === 0) {
                  queueBootstrapFeedRefresh({
                    queryClient: qc,
                    publicationKey: normalizeAtRepoParam(
                      event.payload.publicationId
                    ),
                    oauthSession: oauth,
                    viewerDid: did,
                  });
                }
              }
              if (event.kind === "done") {
                setBootstrapStreamComplete(true);
                bootstrapCompletedAtRef.current = Date.now();
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

  const unreadCountsByPublicationId = useMemo(
    () =>
      unreadCountsMapFromProjection(
        cachedProjection ?? mergedProjection ?? undefined
      ),
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

  const refreshUnreadCountsFromAppViewImpl = useCallback(async () => {
    const oauth = getOAuthSession();
    if (!oauth || !did) return;

    const completedAt = bootstrapCompletedAtRef.current;
    if (completedAt != null && Date.now() - completedAt < 5000) {
      return;
    }

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

  const refreshUnreadCountsFromAppView = useCallback(async () => {
    if (unreadRefreshDebounceRef.current != null) {
      clearTimeout(unreadRefreshDebounceRef.current);
    }
    return new Promise<void>((resolve) => {
      unreadRefreshDebounceRef.current = setTimeout(() => {
        unreadRefreshDebounceRef.current = null;
        void refreshUnreadCountsFromAppViewImpl().finally(resolve);
      }, 300);
    });
  }, [refreshUnreadCountsFromAppViewImpl]);

  useEffect(() => {
    return () => {
      if (unreadRefreshDebounceRef.current != null) {
        clearTimeout(unreadRefreshDebounceRef.current);
      }
    };
  }, []);

  const bootstrap: SidebarBootstrapState = useMemo(
    () => ({
      streamSelectedPublicationId,
      sidebarFetching,
      bootstrapStreamComplete,
      folderPublicationsLoading,
      hasSidebarSnapshot,
      sidebarListsLoading,
      foldersListLoading,
      subscribedPublicationsLoading,
      followingPublicationsLoading,
      folderPublicationsListLoading,
      projectionError,
      refresh,
      refreshUnreadCountsFromAppView,
      viewerDid: session?.did,
    }),
    [
      streamSelectedPublicationId,
      sidebarFetching,
      bootstrapStreamComplete,
      folderPublicationsLoading,
      hasSidebarSnapshot,
      sidebarListsLoading,
      foldersListLoading,
      subscribedPublicationsLoading,
      followingPublicationsLoading,
      folderPublicationsListLoading,
      projectionError,
      refresh,
      refreshUnreadCountsFromAppView,
      session?.did,
    ]
  );

  const normalizedCachedProjection = cachedProjection ?? undefined;

  const value = useMemo(
    (): PublicationSidebarContextValue => ({
      mergedProjection,
      cachedProjection: normalizedCachedProjection,
      projectionState,
      unreadCountsByPublicationId,
      bootstrap,
    }),
    [
      mergedProjection,
      normalizedCachedProjection,
      projectionState,
      unreadCountsByPublicationId,
      bootstrap,
    ]
  );

  return (
    <PublicationSidebarContext.Provider value={value}>
      {children}
    </PublicationSidebarContext.Provider>
  );
}

function usePublicationSidebarContext(): PublicationSidebarContextValue {
  const ctx = useContext(PublicationSidebarContext);
  if (!ctx) {
    throw new Error(
      "useSidebarProjection/useSidebarBootstrap requires PublicationSidebarProvider"
    );
  }
  return ctx;
}

/** Read-only sidebar projection and derived publication lists. */
export function useSidebarProjection() {
  const { mergedProjection, cachedProjection, projectionState, unreadCountsByPublicationId } =
    usePublicationSidebarContext();

  return useMemo(
    () => ({
      publicationSidebarProjection: mergedProjection,
      cachedProjection,
      folders: projectionState?.folders ?? [],
      prefsMap: projectionState?.prefsMap ?? new Map(),
      allPublicationRows: projectionState?.allPublicationRows ?? [],
      folderMap: projectionState?.folderMap ?? new Map(),
      myPublications: projectionState?.myPublications ?? [],
      unfolderedPubs: projectionState?.unfolderedPubs ?? [],
      followingTabPublications: projectionState?.followingTabPublications ?? [],
      sidebarRowsById: projectionState?.sidebarRowsById,
      enrollAuthorDids: projectionState?.enrollAuthorDids ?? [],
      unreadCountsByPublicationId,
      unreadCountsLoading: false,
    }),
    [
      mergedProjection,
      cachedProjection,
      projectionState,
      unreadCountsByPublicationId,
    ]
  );
}

/** Bootstrap stream lifecycle, loading flags, and refresh actions. */
export function useSidebarBootstrap(): SidebarBootstrapState {
  return usePublicationSidebarContext().bootstrap;
}
