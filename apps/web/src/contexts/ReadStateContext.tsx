"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import {
  useQueryClient,
  type InfiniteData,
} from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import {
  loadReadState,
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
import type { EntriesPage } from "@/hooks/useEntries";

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
  /** Bumps when readMap changes; use in unread memo deps. */
  readEpoch: number;
};

const ReadStateContext = createContext<ReadStateContextValue | null>(null);

export function ReadStateProvider({ children }: { children: ReactNode }) {
  const [readMap, setReadMap] = useState<EntryReadStateV1>({});
  const [readEpoch, setReadEpoch] = useState(0);

  const bumpReadEpoch = useCallback(() => {
    setReadEpoch((e) => e + 1);
  }, []);

  const queryClient = useQueryClient();
  const { session, getOAuthSession } = useAuth();
  const viewerDid = session?.did;

  useEffect(() => {
    if (typeof window === "undefined") return;
    queueMicrotask(() => {
      setReadMap(loadReadState(window.localStorage));
    });
  }, []);

  const syncReadMarkToAppView = useCallback(
    (entryId: string, readAt: string) => {
      if (!isThinAppViewEnabled()) return;
      const oauth = getOAuthSession();
      if (!oauth) return;
      void writeThroughReadMark(oauth, entryId, readAt).catch(() => {
        /* best-effort AppView sync */
      });
    },
    [getOAuthSession]
  );

  const syncUnreadMarkToAppView = useCallback(
    (entryId: string) => {
      if (!isThinAppViewEnabled()) return;
      const oauth = getOAuthSession();
      if (!oauth) return;
      void writeThroughReadMarkDelete(oauth, entryId)
        .then(() => {
          if (!viewerDid) return;
          return queryClient.invalidateQueries({
            predicate: ({ queryKey }) =>
              (queryKey[0] === "entries" ||
                queryKey[0] === "aggregateEntries") &&
              queryKey[1] === viewerDid &&
              queryKey[queryKey.length - 1] === "unread",
          });
        })
        .catch(() => {
          /* best-effort AppView sync */
        });
    },
    [getOAuthSession, queryClient, viewerDid]
  );

  const markEntryRead = useCallback(
    (entryId: string, options?: MarkEntryReadOptions) => {
      setReadMap((prev) => {
        if (prev[entryId]) return prev;
        const readAt = new Date().toISOString();
        const next = { ...prev, [entryId]: readAt };
        if (typeof window !== "undefined") {
          saveReadState(window.localStorage, next);
        }
        syncReadMarkToAppView(entryId, readAt);
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
    [bumpReadEpoch, queryClient, syncReadMarkToAppView, viewerDid]
  );

  const markEntryUnread = useCallback(
    (entryId: string, options?: MarkEntryReadOptions) => {
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
          saveReadState(window.localStorage, next);
        }
        syncUnreadMarkToAppView(entryId);
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
    [bumpReadEpoch, queryClient, syncUnreadMarkToAppView, viewerDid]
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
          saveReadState(window.localStorage, next);
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
    [bumpReadEpoch, queryClient, syncReadMarkToAppView, viewerDid]
  );

  const markEntriesUnread = useCallback(
    (entryIds: string[], options?: MarkEntriesReadOptions) => {
      if (entryIds.length === 0) return;
      const unique = [...new Set(entryIds)];
      const unreadIds = new Set(unique);
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
          saveReadState(window.localStorage, next);
        }
        for (const id of removed) {
          syncUnreadMarkToAppView(id);
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
    [bumpReadEpoch, queryClient, syncUnreadMarkToAppView, viewerDid]
  );

  const isEntryRead = useCallback(
    (entryId: string) => Boolean(readMap[entryId]),
    [readMap]
  );

  const value = useMemo(
    (): ReadStateContextValue => ({
      isEntryRead,
      readEpoch,
      markEntryRead,
      markEntryUnread,
      markEntriesRead,
      markEntriesUnread,
    }),
    [
      isEntryRead,
      readEpoch,
      markEntryRead,
      markEntryUnread,
      markEntriesRead,
      markEntriesUnread,
    ]
  );

  return (
    <ReadStateContext.Provider value={value}>{children}</ReadStateContext.Provider>
  );
}

export function useReadState(): ReadStateContextValue {
  const ctx = useContext(ReadStateContext);
  if (!ctx) {
    throw new Error("useReadState must be used within ReadStateProvider");
  }
  return ctx;
}
