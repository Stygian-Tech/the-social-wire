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
  useQueryClient,
  type InfiniteData,
} from "@tanstack/react-query";
import { invalidateConfirmedReadStateQueries, pendingReadStateOverlay } from "@/lib/pendingReadStateOverlay";
import { usePendingPDSReadState } from "@/hooks/usePendingPDSReadState";
import { useAuth } from "@/hooks/useAuth";
import {
  loadReadState,
  READ_STATE_STORAGE_KEY,
  viewerReadStateStorageKey,
  saveReadState,
  type EntryReadStateV1,
} from "@/lib/entryReadStateStorage";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import {
  applyBulkPublicationUnreadCountDeltas,
  applyPublicationUnreadCountDelta,
  bulkUnreadDeltasForPublications,
  clearPublicationUnreadCounts,
} from "@/lib/optimisticUnreadCounts";
import {
  isThinAppViewEnabled,
  writeThroughReadMark,
  writeThroughReadMarkDelete,
} from "@/lib/thinAppViewClient";
import { publicationEntryIsCached } from "@/lib/unreadCounts";
import { PDS_READ_STATE_SYNC_EVENT, loadPDSReadStateSync, pdsReadStateEnabled, usesPDSReadState } from "@/lib/pdsReadStateRuntime";
import { PDSReadStateSyncNotice } from "@/components/Account/PDSReadStateSyncNotice";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { invalidateReadFeedRefreshes, recordReadEntryMutations } from "@/lib/feedRefreshCoordinator";
import type { EntriesPage } from "@/hooks/useEntries";

type LocalReadAction = {
  oauth: OAuthSession;
  read: boolean;
  previousRead: boolean;
  previousReadAt?: string;
  phase: "saving" | "pds";
};

const isViewerReadFeed = (key: readonly unknown[], viewer: string) =>
  key[1] === viewer && (key[0] === "entries" || key[0] === "aggregateEntries");

function patchReadFeedRows(client: ReturnType<typeof useQueryClient>, viewer: string, entryId: string, read: boolean) {
  client.setQueriesData<InfiniteData<EntriesPage>>({ predicate: query => isViewerReadFeed(query.queryKey, viewer) }, current => current ? {
    ...current,
    pages: current.pages.map(page => ({ ...page, entries: page.entries.map(entry => entry.entryId === entryId ? { ...entry, isRead: read } : entry) })),
  } : current);
}

export type MarkEntryReadOptions = {
  publicationId?: string;
};

export type MarkEntriesReadOptions = {
  publications?: DiscoveredPublication[];
  /** When false, skip per-entry AppView writes; bulk mark-all-read uses the scoped AppView endpoint instead. */
  syncToAppView?: boolean;
};

export type ReadStateContextValue = {
  markEntryRead: (entryId: string, options?: MarkEntryReadOptions) => void;
  markEntryUnread: (entryId: string, options?: MarkEntryReadOptions) => void;
  markEntriesRead: (entryIds: string[], options?: MarkEntriesReadOptions) => void;
  markEntriesUnread: (entryIds: string[], options?: MarkEntriesReadOptions) => void;
  /** Returns whether the entry is marked read in local state. */
  isEntryRead: (entryId: string) => boolean;
  pendingEntryReadState: (entryId: string) => boolean | undefined;
  /** Bumps when readMap changes; use in unread memo deps. */
  readEpoch: number;
};

const ReadStateContext = createContext<ReadStateContextValue | null>(null);

export function ReadStateProvider({ children }: { children: ReactNode }) {
  const [readMaps, setReadMaps] = useState<Record<string, EntryReadStateV1>>({});
  const pendingReadStates = usePendingPDSReadState();
  const [readEpoch, setReadEpoch] = useState(0);
  const actions = useRef(new Map<string, LocalReadAction>());
  const writes = useRef(new WeakMap<OAuthSession, Map<string, Promise<void>>>());
  const acceptedStates = useRef(new Map<string, { read: boolean; readAt?: string }>());
  const [mutationError, setMutationError] = useState<{ viewer: string; message: string }>();

  const bumpReadEpoch = useCallback(() => {
    setReadEpoch((e) => e + 1);
  }, []);

  const queryClient = useQueryClient();
  const { session, getOAuthSession } = useAuth();
  const viewerDid = session?.did;
  const pendingEntryReadState = useCallback((entryId: string) => {
    void readEpoch;
    return actions.current.get(`${viewerDid}:${entryId}`)?.read ?? pendingReadStates.get(entryId);
  }, [pendingReadStates, readEpoch, viewerDid]);
  const storageKey = pdsReadStateEnabled() ? viewerReadStateStorageKey(viewerDid) : READ_STATE_STORAGE_KEY;
  const readMap = useMemo(() => readMaps[storageKey] ?? {}, [readMaps, storageKey]);
  const setReadMap = useCallback((update: EntryReadStateV1 | ((previous: EntryReadStateV1) => EntryReadStateV1)) => {
    setReadMaps(previous => ({ ...previous, [storageKey]: typeof update === "function" ? update(previous[storageKey] ?? {}) : update }));
  }, [storageKey]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    queueMicrotask(() => {
      setReadMap(loadReadState(window.localStorage, storageKey));
    });
  }, [setReadMap, storageKey]);

  const actionIsCurrent = useCallback((entryId: string, action: LocalReadAction) =>
    getOAuthSession() === action.oauth && actions.current.get(`${action.oauth.did}:${entryId}`) === action,
  [getOAuthSession]);

  const reconcileAction = useCallback(async (entryId: string, action: LocalReadAction, error?: unknown) => {
    if (!actionIsCurrent(entryId, action)) return;
    const viewer = action.oauth.did;
    invalidateReadFeedRefreshes(queryClient, action.oauth);
    await queryClient.cancelQueries({ predicate: query => isViewerReadFeed(query.queryKey, viewer) });
    if (!actionIsCurrent(entryId, action)) return;
    const baseline = acceptedStates.current.get(`${viewer}:${entryId}`) ?? { read: action.previousRead, readAt: action.previousReadAt };
    patchReadFeedRows(queryClient, viewer, entryId, error ? baseline.read : action.read);
    if (error) {
      setReadMap(previous => {
        const next = { ...previous };
        if (baseline.readAt) next[entryId] = baseline.readAt;
        else delete next[entryId];
        saveReadState(window.localStorage, next, storageKey);
        return next;
      });
      setMutationError({ viewer, message: "Could not confirm this read-state change. Please try again." });
    }
    actions.current.delete(`${viewer}:${entryId}`);
    acceptedStates.current.delete(`${viewer}:${entryId}`);
    bumpReadEpoch();
    void invalidateConfirmedReadStateQueries(queryClient, viewer).catch(() => {});
  }, [actionIsCurrent, bumpReadEpoch, queryClient, setReadMap, storageKey]);

  const synchronizeEntryState = useCallback((entryId: string, read: boolean, readAt?: string) => {
    if (!isThinAppViewEnabled()) return;
    const oauth = getOAuthSession();
    if (!oauth) return;
    const key = `${oauth.did}:${entryId}`;
    const previous = actions.current.get(key);
    const cachedRead = queryClient.getQueriesData<InfiniteData<EntriesPage>>({ predicate: query => isViewerReadFeed(query.queryKey, oauth.did) })
      .some(([, value]) => value?.pages.some(page => page.entries.some(entry => entry.entryId === entryId && entry.isRead)));
    const action: LocalReadAction = {
      oauth, read, phase: "saving", previousReadAt: readMap[entryId],
      previousRead: previous?.read ?? pendingReadStates.get(entryId) ?? (Boolean(readMap[entryId]) || cachedRead),
    };
    if (!acceptedStates.current.has(key)) acceptedStates.current.set(key, { read: action.previousRead, readAt: action.previousReadAt });
    actions.current.set(key, action);
    setMutationError(undefined);
    bumpReadEpoch();
    recordReadEntryMutations(queryClient, oauth, [entryId]);
    void queryClient.cancelQueries({ predicate: query => isViewerReadFeed(query.queryKey, oauth.did) }).then(() => {
      if (actionIsCurrent(entryId, action)) patchReadFeedRows(queryClient, oauth.did, entryId, read);
    }).catch(() => {});
    let queue = writes.current.get(oauth);
    if (!queue) { queue = new Map(); writes.current.set(oauth, queue); }
    const pending = queue.get(entryId) ?? Promise.resolve();
    const task = pending.catch(() => {}).then(async () => {
      if (!actionIsCurrent(entryId, action)) return;
      if (read) await writeThroughReadMark(oauth, entryId, readAt ?? new Date().toISOString());
      else await writeThroughReadMarkDelete(oauth, entryId);
      if (getOAuthSession() === oauth) acceptedStates.current.set(key, { read, readAt: read ? readAt : undefined });
      if (!actionIsCurrent(entryId, action)) return;
      action.phase = "pds";
      if (await usesPDSReadState(oauth)) {
        // The explicit gesture bridges the async enqueue and confirmation windows.
        // The durable outbox remains the source of retry and PDS authority rules.
        const snapshot = await (await loadPDSReadStateSync(oauth)).snapshot();
        if (!pendingReadStateOverlay(snapshot, oauth.did).has(entryId)) await reconcileAction(entryId, action);
      } else await reconcileAction(entryId, action);
    }).catch(error => reconcileAction(entryId, action, error));
    queue.set(entryId, task);
    void task.finally(() => { if (queue.get(entryId) === task) queue.delete(entryId); }).catch(() => {});
  }, [actionIsCurrent, bumpReadEpoch, getOAuthSession, pendingReadStates, queryClient, readMap, reconcileAction]);

  const syncReadMarkToAppView = useCallback((entryId: string, readAt: string) => {
    synchronizeEntryState(entryId, true, readAt);
  }, [synchronizeEntryState]);
  const syncUnreadMarkToAppView = useCallback((entryId: string) => {
    synchronizeEntryState(entryId, false);
  }, [synchronizeEntryState]);

  useEffect(() => {
    const oauth = getOAuthSession();
    // A later account switch cannot revive a queued action from an old session.
    for (const [key, action] of actions.current) if (action.oauth !== oauth) {
      actions.current.delete(key); acceptedStates.current.delete(key);
    }
  }, [getOAuthSession, viewerDid]);

  useEffect(() => {
    const confirmed = (event: Event) => {
      const detail = (event as CustomEvent<{ viewerDid: string; kind: string }>).detail;
      if (detail?.viewerDid !== viewerDid || detail.kind !== "confirmed") return;
      const oauth = getOAuthSession();
      if (!oauth || oauth.did !== viewerDid) return;
      const candidates = [...actions.current].filter(([, action]) => action.oauth === oauth && action.phase === "pds");
      void loadPDSReadStateSync(oauth).then(runtime => runtime.snapshot()).then(async snapshot => {
        if (getOAuthSession() !== oauth) return;
        const pending = pendingReadStateOverlay(snapshot, oauth.did);
        for (const [key, action] of candidates) {
          const entryId = key.slice(oauth.did.length + 1);
          if (!pending.has(entryId)) await reconcileAction(entryId, action);
        }
        if (getOAuthSession() !== oauth || snapshot.entries.length !== 0 ||
          [...actions.current.values()].some(action => action.oauth === oauth)) return;
        setReadMap({}); saveReadState(window.localStorage, {}, storageKey); bumpReadEpoch();
      }).catch(() => {});
      void invalidateConfirmedReadStateQueries(queryClient, oauth.did).catch(() => {});
    };
    window.addEventListener(PDS_READ_STATE_SYNC_EVENT, confirmed);
    return () => window.removeEventListener(PDS_READ_STATE_SYNC_EVENT, confirmed);
  }, [bumpReadEpoch, getOAuthSession, queryClient, reconcileAction, setReadMap, storageKey, viewerDid]);

  const markEntryRead = useCallback(
    (entryId: string, options?: MarkEntryReadOptions) => {
      const pending = pendingEntryReadState(entryId);
      if (pending === true || pending !== false && readMap[entryId]) return;
      const readAt = new Date().toISOString();
      syncReadMarkToAppView(entryId, readAt);
      setReadMap((prev) => {
        if (prev[entryId]) return prev;
        const next = { ...prev, [entryId]: readAt };
        if (typeof window !== "undefined") {
          saveReadState(window.localStorage, next, storageKey);
        }
        if (viewerDid && options?.publicationId) {
          const publicationId = options.publicationId;
          queueMicrotask(() => {
            if (
              publicationEntryIsCached(queryClient, viewerDid, publicationId, entryId)
            ) {
              return;
            }
            applyPublicationUnreadCountDelta(
              queryClient,
              viewerDid,
              publicationId,
              -1
            );
          });
        }
        bumpReadEpoch();
        return next;
      });
    },
    [bumpReadEpoch, pendingEntryReadState, queryClient, readMap, setReadMap, storageKey, syncReadMarkToAppView, viewerDid]
  );

  const markEntryUnread = useCallback(
    (entryId: string, options?: MarkEntryReadOptions) => {
      syncUnreadMarkToAppView(entryId);
      if (viewerDid) {
        queryClient.setQueriesData<InfiniteData<EntriesPage>>(
          {
            predicate: ({ queryKey }) =>
              (queryKey[0] === "entries" ||
                queryKey[0] === "aggregateEntries") &&
              queryKey[1] === viewerDid,
          },
          (current) =>
            current
              ? {
                  ...current,
                  pages: current.pages.map((page) => ({
                    ...page,
                    entries: page.entries.map((entry) =>
                      entry.entryId === entryId
                        ? { ...entry, isRead: false }
                        : entry
                    ),
                  })),
                }
              : current
        );
      }
      setReadMap((prev) => {
        if (!prev[entryId]) return prev;
        const next = { ...prev };
        delete next[entryId];
        if (typeof window !== "undefined") {
          saveReadState(window.localStorage, next, storageKey);
        }
        if (viewerDid && options?.publicationId) {
          const publicationId = options.publicationId;
          queueMicrotask(() => {
            if (
              publicationEntryIsCached(queryClient, viewerDid, publicationId, entryId)
            ) {
              return;
            }
            applyPublicationUnreadCountDelta(
              queryClient,
              viewerDid,
              publicationId,
              1
            );
          });
        }
        bumpReadEpoch();
        return next;
      });
    },
    [bumpReadEpoch, queryClient, setReadMap, storageKey, syncUnreadMarkToAppView, viewerDid]
  );

  const markEntriesRead = useCallback(
    (entryIds: string[], options?: MarkEntriesReadOptions) => {
      if (entryIds.length === 0) return;
      const unique = [...new Set(entryIds)];
      let didMarkAny = false;
      setReadMap((prev) => {
        const readAt = new Date().toISOString();
        const next = { ...prev };
        const toSync: string[] = [];
        for (const id of unique) {
          if (!next[id]) {
            next[id] = readAt;
            toSync.push(id);
          }
        }
        if (toSync.length === 0) return prev;
        didMarkAny = true;
        if (typeof window !== "undefined") {
          saveReadState(window.localStorage, next, storageKey);
        }
        if (options?.syncToAppView !== false) {
          for (const id of toSync) {
            syncReadMarkToAppView(id, readAt);
          }
        }
        return next;
      });
      if (didMarkAny) {
        bumpReadEpoch();
      }
      if (didMarkAny && viewerDid && options?.publications?.length) {
        clearPublicationUnreadCounts(
          queryClient,
          viewerDid,
          options.publications
        );
      }
    },
    [bumpReadEpoch, queryClient, setReadMap, storageKey, syncReadMarkToAppView, viewerDid]
  );

  const markEntriesUnread = useCallback(
    (entryIds: string[], options?: MarkEntriesReadOptions) => {
      if (entryIds.length === 0) return;
      const unique = [...new Set(entryIds)];
      const unreadIds = new Set(unique);
      for (const id of unique) syncUnreadMarkToAppView(id);
      if (viewerDid) {
        queryClient.setQueriesData<InfiniteData<EntriesPage>>(
          {
            predicate: ({ queryKey }) =>
              (queryKey[0] === "entries" ||
                queryKey[0] === "aggregateEntries") &&
              queryKey[1] === viewerDid,
          },
          (current) =>
            current
              ? {
                  ...current,
                  pages: current.pages.map((page) => ({
                    ...page,
                    entries: page.entries.map((entry) =>
                      unreadIds.has(entry.entryId)
                        ? { ...entry, isRead: false }
                        : entry
                    ),
                  })),
                }
              : current
        );
      }
      const bulkDeltasRef: { current: Map<string, number> | null } = {
        current: null,
      };
      setReadMap((prev) => {
        const next = { ...prev };
        const removed: string[] = [];
        for (const id of unique) {
          if (next[id]) {
            delete next[id];
            removed.push(id);
          }
        }
        if (removed.length === 0) return prev;
        if (typeof window !== "undefined") {
          saveReadState(window.localStorage, next, storageKey);
        }
        if (viewerDid && options?.publications?.length) {
          bulkDeltasRef.current = bulkUnreadDeltasForPublications(
            queryClient,
            viewerDid,
            options.publications,
            (entryId) => Boolean(prev[entryId])
          );
        }
        return next;
      });
      if (bulkDeltasRef.current && bulkDeltasRef.current.size > 0) {
        bumpReadEpoch();
      }
      if (viewerDid && bulkDeltasRef.current && bulkDeltasRef.current.size > 0) {
        applyBulkPublicationUnreadCountDeltas(
          queryClient,
          viewerDid,
          bulkDeltasRef.current
        );
      }
    },
    [bumpReadEpoch, queryClient, setReadMap, storageKey, syncUnreadMarkToAppView, viewerDid]
  );

  const isEntryRead = useCallback(
    (entryId: string) => pendingEntryReadState(entryId) ?? Boolean(readMap[entryId]),
    [readMap, pendingEntryReadState]
  );

  const value = useMemo(
    (): ReadStateContextValue => ({
      isEntryRead,
      pendingEntryReadState,
      readEpoch,
      markEntryRead,
      markEntryUnread,
      markEntriesRead,
      markEntriesUnread,
    }),
    [
      isEntryRead,
      pendingEntryReadState,
      readEpoch,
      markEntryRead,
      markEntryUnread,
      markEntriesRead,
      markEntriesUnread,
    ]
  );

  return (
    <ReadStateContext.Provider value={value}>
      {children}
      <div className="fixed bottom-4 right-4 z-50 flex w-[calc(100vw-2rem)] max-w-sm flex-col gap-2">
        {mutationError && mutationError.viewer === viewerDid ? (
          <aside role="alert" className="rounded-xl border bg-background p-3 text-sm shadow-md">
            <p>{mutationError.message}</p>
            <button type="button" className="mt-1 underline" onClick={() => setMutationError(undefined)}>Dismiss</button>
          </aside>
        ) : null}
        <PDSReadStateSyncNotice />
      </div>
    </ReadStateContext.Provider>
  );
}

export function useReadState(): ReadStateContextValue {
  const ctx = useContext(ReadStateContext);
  if (!ctx) {
    throw new Error("useReadState must be used within ReadStateProvider");
  }
  return ctx;
}
