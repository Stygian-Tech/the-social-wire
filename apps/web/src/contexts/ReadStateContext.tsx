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
import { useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { usePDSClient } from "@/hooks/usePDSClient";
import {
  loadReadState,
  mergeReadStateMaps,
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
import { publicationEntryIsCached } from "@/lib/unreadCounts";

export type MarkEntryReadOptions = {
  publicationId?: string;
};

export type MarkEntriesReadOptions = {
  publications?: DiscoveredPublication[];
  /** When false, skip per-entry PDS writes (optimistic UI only). */
  syncToPds?: boolean;
};

export type ReadStateContextValue = {
  markEntryRead: (entryId: string, options?: MarkEntryReadOptions) => void;
  markEntryUnread: (entryId: string, options?: MarkEntryReadOptions) => void;
  markEntriesRead: (entryIds: string[], options?: MarkEntriesReadOptions) => void;
  markEntriesUnread: (entryIds: string[], options?: MarkEntriesReadOptions) => void;
  /** Stable callback identity — reads latest readMap via ref. */
  isEntryRead: (entryId: string) => boolean;
  /** Bumps when readMap changes; use in unread memo deps. */
  readEpoch: number;
  syncReadStateFromPDS: () => Promise<void>;
};

const ReadStateContext = createContext<ReadStateContextValue | null>(null);

export function ReadStateProvider({ children }: { children: ReactNode }) {
  const [readMap, setReadMap] = useState<EntryReadStateV1>({});
  const [readEpoch, setReadEpoch] = useState(0);
  const readMapRef = useRef(readMap);
  readMapRef.current = readMap;

  const bumpReadEpoch = useCallback(() => {
    setReadEpoch((e) => e + 1);
  }, []);

  const pdsClient = usePDSClient();
  const queryClient = useQueryClient();
  const { session } = useAuth();
  const viewerDid = session?.did;

  useEffect(() => {
    if (typeof window === "undefined") return;
    queueMicrotask(() => {
      setReadMap(loadReadState(window.localStorage));
    });
  }, []);

  useEffect(() => {
    if (typeof window === "undefined") return;
    if (!pdsClient) return;

    let cancelled = false;
    void (async () => {
      try {
        const remote = await pdsClient.listEntryReadStateMap();
        if (cancelled) return;
        const local = loadReadState(window.localStorage);
        const merged = mergeReadStateMaps(local, remote);
        setReadMap(merged);
        setReadEpoch((e) => e + 1);
        saveReadState(window.localStorage, merged);
      } catch {
        /* network / OAuth scope / PDS — keep local cache */
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [pdsClient]);

  const markEntryRead = useCallback(
    (entryId: string, options?: MarkEntryReadOptions) => {
      setReadMap((prev) => {
        if (prev[entryId]) return prev;
        const readAt = new Date().toISOString();
        const next = { ...prev, [entryId]: readAt };
        if (typeof window !== "undefined") {
          saveReadState(window.localStorage, next);
        }
        if (pdsClient) {
          void pdsClient.putEntryReadState(entryId, readAt).catch(() => {
            /* best-effort sync */
          });
        }
        if (viewerDid && options?.publicationId) {
          const publicationId = options.publicationId;
          queueMicrotask(() => {
            if (
              publicationEntryIsCached(queryClient, publicationId, entryId)
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
    [bumpReadEpoch, pdsClient, queryClient, viewerDid]
  );

  const markEntryUnread = useCallback(
    (entryId: string, options?: MarkEntryReadOptions) => {
      setReadMap((prev) => {
        if (!prev[entryId]) return prev;
        const next = { ...prev };
        delete next[entryId];
        if (typeof window !== "undefined") {
          saveReadState(window.localStorage, next);
        }
        if (pdsClient) {
          void pdsClient.deleteEntryReadState(entryId).catch(() => {
            /* best-effort sync */
          });
        }
        if (viewerDid && options?.publicationId) {
          const publicationId = options.publicationId;
          queueMicrotask(() => {
            if (
              publicationEntryIsCached(queryClient, publicationId, entryId)
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
    [bumpReadEpoch, pdsClient, queryClient, viewerDid]
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
        if (pdsClient && options?.syncToPds !== false) {
          for (const id of toSync) {
            void pdsClient.putEntryReadState(id, readAt).catch(() => {
              /* best-effort sync */
            });
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
    [bumpReadEpoch, pdsClient, queryClient, viewerDid]
  );

  const markEntriesUnread = useCallback(
    (entryIds: string[], options?: MarkEntriesReadOptions) => {
      if (entryIds.length === 0) return;
      const unique = [...new Set(entryIds)];
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
        if (pdsClient) {
          for (const id of removed) {
            void pdsClient.deleteEntryReadState(id).catch(() => {
              /* best-effort sync */
            });
          }
        }
        if (viewerDid && options?.publications?.length) {
          bulkDeltasRef.current = bulkUnreadDeltasForPublications(
            queryClient,
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
    [bumpReadEpoch, pdsClient, queryClient, viewerDid]
  );

  const isEntryRead = useCallback((entryId: string) => {
    return Boolean(readMapRef.current[entryId]);
  }, []);

  const syncReadStateFromPDS = useCallback(async () => {
    if (!pdsClient) return;
    try {
      const remote = await pdsClient.listEntryReadStateMap();
      setReadMap((local) => {
        const merged = mergeReadStateMaps(local, remote);
        if (typeof window !== "undefined") {
          saveReadState(window.localStorage, merged);
        }
        setReadEpoch((e) => e + 1);
        return merged;
      });
    } catch {
      /* network / OAuth scope / PDS — keep local cache */
    }
  }, [pdsClient]);

  const value = useMemo(
    (): ReadStateContextValue => ({
      isEntryRead,
      readEpoch,
      markEntryRead,
      markEntryUnread,
      markEntriesRead,
      markEntriesUnread,
      syncReadStateFromPDS,
    }),
    [
      isEntryRead,
      readEpoch,
      markEntryRead,
      markEntryUnread,
      markEntriesRead,
      markEntriesUnread,
      syncReadStateFromPDS,
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
