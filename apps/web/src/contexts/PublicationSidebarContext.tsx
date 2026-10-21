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
  type InfiniteData,
} from "@tanstack/react-query";
import { mergeStandardReaderListsPage, standardReaderListsQueryKey } from "@/lib/standardReaderListsClient";
import { useAuth } from "@/hooks/useAuth";
import { ENTRIES_QUERY_KEY, type EntriesPage } from "@/hooks/useEntries";
import { queueBootstrapFeedRefresh } from "@/hooks/useProactiveFeedRefresh";
import { consumeBootstrapStream } from "@/lib/bootstrapStreamClient";
import { readFeedRefreshRevision } from "@/lib/feedRefreshCoordinator";
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
import {
  dummyPublicationSidebarProjection,
  isDummyReaderDataEnabled,
} from "@/lib/dummyReaderData";
import { PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY } from "@/lib/sidebarQueryKeys";
import {
  projectionToSidebarState,
  sidebarListShowsSkeleton,
  type SidebarProjectionState,
} from "@/lib/sidebarProjectionState";
import { awaitWithAbort } from "@/lib/awaitWithAbort";
import { refreshReaderUnreadCounts } from "@/lib/refreshReaderUnreadCounts";
import { refreshReaderFeeds } from "@/lib/refreshReaderFeeds";
import { readerRefreshRows, refreshPublicationSources } from "@/lib/refreshPublicationSources";
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
  refreshMessage: string;
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
const EMPTY_PUBLICATION_ROWS: SidebarProjectionState["allPublicationRows"] = [];

const RECENT_BOOTSTRAP_REUSE_MS = 30_000;
export const MANUAL_SIDEBAR_REFRESH_TIMEOUT_MS = 30_000;
const bootstrapCompletedAtByDid = new Map<string, number>();

export function PublicationSidebarProvider({ children }: { children: ReactNode }) {
  const auth = useAuth();
  const did = auth.session?.did ?? "";

  return (
    <PublicationSidebarProviderInner key={did} auth={auth}>
      {children}
    </PublicationSidebarProviderInner>
  );
}

function PublicationSidebarProviderInner({
  auth,
  children,
}: {
  auth: ReturnType<typeof useAuth>;
  children: ReactNode;
}) {
  const dummyReaderDataEnabled = isDummyReaderDataEnabled();
  const { session, getOAuthSession, oauthSessionReloadSeq } = auth;
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
  const manualRefreshControllerRef = useRef<AbortController | null>(null);
  const streamSawSidebarSectionRef = useRef(false);
  const pendingAutoSelectPublicationIdRef = useRef<string | null>(null);
  const bootstrapFeedPublicationIdRef = useRef<string | null>(null);
  const bootstrapCompletedAtRef = useRef<{
    did: string;
    completedAt: number;
  } | null>(null);
  const [refreshMessage, setRefreshMessage] = useState("");
  const manualRefreshRef = useRef<{ controller: AbortController; task: Promise<void> } | null>(null);
  useEffect(() => () => manualRefreshRef.current?.controller.abort(), [oauthSessionReloadSeq]);

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

  const mergedProjection =
    dummyReaderDataEnabled
      ? cachedProjection ?? dummyPublicationSidebarProjection
      : streamProjection ?? cachedProjection ?? undefined;

  useEffect(() => {
    if (!dummyReaderDataEnabled || !did) return;
    const queryKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
    if (!qc.getQueryData<PublicationSidebarProjection>(queryKey)) {
      qc.setQueryData(queryKey, dummyPublicationSidebarProjection);
    }
  }, [did, dummyReaderDataEnabled, qc]);

  const runBootstrapStream = useCallback(
    async (
      controller: AbortController,
      options: { force?: boolean } = {}
    ) => {
      const oauth = getOAuthSession();
      if (!oauth || !did) return;
      controller.signal.throwIfAborted();

      resetBootstrapPerf();
      const queryKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
      const hadSidebarSnapshot = Boolean(
        qc.getQueryData<PublicationSidebarProjection>(queryKey)
      );
      if (hadSidebarSnapshot) {
        markBootstrapPerf("cachedSidebarPaint");
      }

      const recentCompletedAt = bootstrapCompletedAtByDid.get(did);
      if (
        !options.force &&
        hadSidebarSnapshot &&
        recentCompletedAt != null &&
        Date.now() - recentCompletedAt < RECENT_BOOTSTRAP_REUSE_MS
      ) {
        setSidebarFetching(false);
        setFolderPublicationsLoading(false);
        setBootstrapStreamComplete(true);
        bootstrapCompletedAtRef.current = {
          did,
          completedAt: recentCompletedAt,
        };
        return;
      }

      const generation = ++streamGenerationRef.current;
      const readRevision = readFeedRefreshRevision(qc, oauth);
      streamSawSidebarSectionRef.current = false;
      pendingAutoSelectPublicationIdRef.current = null;
      bootstrapFeedPublicationIdRef.current = null;

      setSidebarFetching(true);
      setBootstrapStreamComplete(false);
      setProjectionError(null);
      setFolderPublicationsLoading(!hadSidebarSnapshot);

      let streamFailure: Error | null = null;
      let sawDone = false;
      try {
        await consumeBootstrapStream({
          oauthSession: oauth,
          signal: controller.signal,
          handlers: {
            onEvent: (event) => {
              if (generation !== streamGenerationRef.current || controller.signal.aborted || getOAuthSession() !== oauth) return;
              if (event.kind === "error" || event.kind === "warning") streamFailure = new Error(event.payload.message);
              if (event.kind === "done") sawDone = true;
              if (event.kind === "lists") {
                const listsKey = standardReaderListsQueryKey(did, oauthSessionReloadSeq);
                qc.setQueryData(listsKey, mergeStandardReaderListsPage(qc.getQueryData(listsKey), event.payload));
                return;
              }

              if (event.kind === "sidebarPriority") {
                markBootstrapPerf("sidebarPriority");
                setSidebarFetching(false);
              }
              if (event.kind === "unreadCounts") {
                markBootstrapPerf("unreadCounts");
              }
              if (event.kind === "sidebarSection") {
                streamSawSidebarSectionRef.current = true;
                markBootstrapPerf("sidebarSection");
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
              if (event.kind === "sidebarSection") {
                setFolderPublicationsLoading(false);
              }
              if (event.kind === "sidebarFolders") {
                setFolderPublicationsLoading(false);
              }
              if (event.kind === "selectedPublication" && !options.force) {
                pendingAutoSelectPublicationIdRef.current =
                  event.payload.publicationId;
                bootstrapFeedPublicationIdRef.current =
                  event.payload.publicationId;
              }
              if (event.kind === "entriesPage" && !options.force) {
                writeStreamedEntriesPage(qc, did, event.payload, "all", { session: oauth, revision: readRevision });
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
                bootstrapCompletedAtRef.current = {
                  did,
                  completedAt: Date.now(),
                };
                bootstrapCompletedAtByDid.set(
                  did,
                  bootstrapCompletedAtRef.current.completedAt
                );
                if (pendingAutoSelectPublicationIdRef.current) {
                  setStreamSelectedPublicationId(
                    pendingAutoSelectPublicationIdRef.current
                  );
                  bootstrapFeedPublicationIdRef.current =
                    bootstrapFeedPublicationIdRef.current ??
                    pendingAutoSelectPublicationIdRef.current;
                  pendingAutoSelectPublicationIdRef.current = null;
                }
                if (bootstrapFeedPublicationIdRef.current && !qc.getQueryData<InfiniteData<EntriesPage>>([
                  ...ENTRIES_QUERY_KEY(did, normalizeAtRepoParam(bootstrapFeedPublicationIdRef.current)), "all",
                ])?.pages.some(page => page.entries.length > 0)) {
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

              const skipLegacySidebarFolders =
                event.kind === "sidebarFolders" &&
                streamSawSidebarSectionRef.current;

              setStreamProjection((currentStream) => {
                if (controller.signal.aborted || generation !== streamGenerationRef.current || getOAuthSession() !== oauth) return currentStream;
                if (skipLegacySidebarFolders) return currentStream;
                const baseline =
                  qc.getQueryData<PublicationSidebarProjection>(
                    queryKey
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
                    queryKey,
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
              if (controller.signal.aborted || generation !== streamGenerationRef.current || getOAuthSession() !== oauth) return;
              streamFailure = error;
              setProjectionError(error);
            },
          },
        });
        if (options.force) {
          controller.signal.throwIfAborted();
          if (streamFailure) throw streamFailure;
          if (!sawDone) throw new Error("Publication refresh ended before completion. Try Refresh again.");
        }
      } catch (error) {
        if (controller.signal.aborted || generation !== streamGenerationRef.current || getOAuthSession() !== oauth) return;
        if (!(error instanceof DOMException && error.name === "AbortError")) {
          setProjectionError(
            error instanceof Error ? error : new Error(String(error))
          );
        }
        if (options.force) throw error;
      } finally {
        if (generation === streamGenerationRef.current) {
          setSidebarFetching(false);
          setFolderPublicationsLoading(false);
        }
      }
    },
    [did, getOAuthSession, oauthSessionReloadSeq, qc]
  );

  useEffect(() => {
    if (dummyReaderDataEnabled) return;
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
  }, [
    dummyReaderDataEnabled,
    session,
    oauthSessionReloadSeq,
    runBootstrapStream,
    getOAuthSession,
  ]);

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
    !dummyReaderDataEnabled && !hasSidebarSnapshot && !isRestoring && sidebarFetching;

  const projectionState = useMemo(() => {
    if (!mergedProjection) return null;
    return projectionToSidebarState(mergedProjection);
  }, [mergedProjection]);

  const unreadCountsByPublicationId = useMemo(
    () => unreadCountsMapFromProjection(mergedProjection ?? undefined),
    [mergedProjection]
  );

  const folders = projectionState?.folders ?? [];
  const unfolderedPubs = projectionState?.unfolderedPubs ?? [];
  const followingTabPublications =
    projectionState?.followingTabPublications ?? [];

  const foldersListLoading = sidebarListShowsSkeleton({
    hasSidebarSnapshot,
    isRestoring,
    sidebarFetching: dummyReaderDataEnabled ? false : sidebarFetching,
    itemCount: folders.length,
  });
  const subscribedPublicationsLoading = sidebarListShowsSkeleton({
    hasSidebarSnapshot,
    isRestoring,
    sidebarFetching: dummyReaderDataEnabled ? false : sidebarFetching,
    itemCount: unfolderedPubs.length,
  });
  const followingPublicationsLoading = sidebarListShowsSkeleton({
    hasSidebarSnapshot,
    isRestoring,
    sidebarFetching: dummyReaderDataEnabled ? false : sidebarFetching,
    itemCount: followingTabPublications.length,
  });
  const folderPublicationsListLoading =
    !dummyReaderDataEnabled &&
    !hasSidebarSnapshot &&
    !isRestoring &&
    folderPublicationsLoading;

  const refresh = useMutation<void, Error, void>({
    mutationFn: () => {
      if (manualRefreshRef.current) return manualRefreshRef.current.task;
      const controller = new AbortController();
      const task = (async () => {
        if (dummyReaderDataEnabled) {
          setRefreshMessage("Refresh Complete");
          return;
        }
        const oauth = getOAuthSession();
        if (!oauth) throw new Error("OAuth session required");
        const signal = controller.signal;
        setRefreshMessage("Checking Publications…");
        const sidebarSignal = AbortSignal.any([signal, AbortSignal.timeout(30_000)]);
        const response = await awaitWithAbort(refreshPublicationSidebar(oauth, sidebarSignal), sidebarSignal);
        signal.throwIfAborted();
        if (getOAuthSession() !== oauth) throw new DOMException("Account changed", "AbortError");
        if (response.viewerDid !== did) throw new Error("Publication details are unavailable. Try Refresh again.");
        // The POST returns the complete authoritative sidebar. Supersede any
        // older initial stream without selecting an article or replacing history.
        streamGenerationRef.current += 1;
        const queryKey = PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did);
        const previous = qc.getQueryData<PublicationSidebarProjection>(queryKey);
        const retainedFollowingIds = new Set(response.retainedFollowingPublicationIds ?? []);
        const following = new Map(response.followingTabPublications.map(row => [row.publicationId, row]));
        for (const row of previous?.followingTabPublications ?? []) {
          if (retainedFollowingIds.has(row.publicationId) && !following.has(row.publicationId)) following.set(row.publicationId, row);
        }
        const allRows = new Map(response.allPublicationRows.map(row => [row.publicationId, row]));
        for (const row of following.values()) if (!allRows.has(row.publicationId)) allRows.set(row.publicationId, row);
        const projection = { ...response, followingTabPublications: [...following.values()], allPublicationRows: [...allRows.values()] };
        qc.setQueryData(queryKey, previous?.unreadCountsByPublicationId && !projection.unreadCountsByPublicationId
          ? applyUnreadCountsEvent(projection, previous.unreadCountsByPublicationId ?? {}, {
              generation: previous.unreadCountsGeneration,
              accuracy: previous.unreadCountsAccuracy,
              countedAt: previous.unreadCountsCountedAt,
            })
          : projection);
        setStreamProjection(undefined);
        setProjectionError(null);
        setSidebarFetching(false);
        setFolderPublicationsLoading(false);
        setBootstrapStreamComplete(true);
        // Remember the operation's starting rows too: an old Unread row can
        // disappear during one paint and resurface later without being new.
        const startingArticleIds = new Set(qc.getQueryCache().findAll({
          predicate: query => query.queryKey[1] === did && (query.queryKey[0] === "entries" || query.queryKey[0] === "aggregateEntries"),
        }).flatMap(query => (query.state.data as InfiniteData<EntriesPage> | undefined)?.pages.flatMap(page => page.entries.map(entry => entry.entryId)) ?? []));
        const newArticleIds = new Set<string>();
        const updateArticles = async () => {
          signal.throwIfAborted();
          await refreshReaderFeeds({
            queryClient: qc, viewerDid: did, oauthSession: oauth, signal,
            onNewArticleIds: ids => {
              signal.throwIfAborted();
              for (const id of ids) if (!startingArticleIds.has(id)) newArticleIds.add(id);
            },
          });
          signal.throwIfAborted();
        };
        const rows = readerRefreshRows(qc, did, projection);
        let sourceFailure: unknown;
        try {
          await refreshPublicationSources({
            oauthSession: oauth,
            rows,
            signal,
            onProgress: (completed, total) => {
              signal.throwIfAborted();
              setRefreshMessage(completed === total ? "Updating Articles…" : `Checking ${total} Publications…`);
            },
            onBatch: updateArticles,
          });
        } catch (error) {
          signal.throwIfAborted();
          sourceFailure = error;
        }
        signal.throwIfAborted();
        setRefreshMessage("Updating Unread Counts…");
        await refreshReaderUnreadCounts({ queryClient: qc, viewerDid: did, oauthSession: oauth, publicationIds: rows.map(row => row.publicationId), signal });
        signal.throwIfAborted();
        if (sourceFailure) throw sourceFailure;
        const newArticleCount = newArticleIds.size;
        setRefreshMessage(newArticleCount > 0 ? `${newArticleCount} New ${newArticleCount === 1 ? "Article" : "Articles"} Loaded` : "Refresh Complete");
      })().finally(() => {
        if (manualRefreshRef.current?.controller === controller) manualRefreshRef.current = null;
      });
      manualRefreshRef.current = { controller, task };
      return task;
    },
  });

  useEffect(() => () => {
    manualRefreshControllerRef.current?.abort();
  }, [did, oauthSessionReloadSeq]);

  const refreshUnreadCountsFromAppViewImpl = useCallback(async () => {
    if (dummyReaderDataEnabled) return;
    const oauth = getOAuthSession();
    if (!oauth || !did) return;

    const completed = bootstrapCompletedAtRef.current;
    if (
      completed?.did === did &&
      Date.now() - completed.completedAt < 5000
    ) {
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
      const countSnapshot = await fetchAppViewUnreadCounts(oauth, publicationIds);
      qc.setQueryData<PublicationSidebarProjection>(
        PUBLICATION_SIDEBAR_PROJECTION_QUERY_KEY(did),
        (current) =>
          current
            ? applyUnreadCountsEvent(current, countSnapshot.counts, {
                replacePublicationIds: publicationIds,
                generation: countSnapshot.generation,
                accuracy: countSnapshot.accuracy,
                countedAt: countSnapshot.countedAt,
              })
            : current
      );
    } catch {
      /* best-effort cross-client sync */
    }
  }, [did, dummyReaderDataEnabled, getOAuthSession, qc]);

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
      refreshMessage,
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
      refreshMessage,
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

/** Publication rows for components that may also render outside the reader shell. */
export function useOptionalSidebarPublicationRows() {
  const context = useContext(PublicationSidebarContext);
  return context?.projectionState?.allPublicationRows ?? EMPTY_PUBLICATION_ROWS;
}

/** Bootstrap stream lifecycle, loading flags, and refresh actions. */
export function useSidebarBootstrap(): SidebarBootstrapState {
  return usePublicationSidebarContext().bootstrap;
}
