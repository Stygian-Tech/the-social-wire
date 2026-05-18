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
import { usePDSClient } from "@/hooks/usePDSClient";
import {
  loadReadState,
  mergeReadStateMaps,
  saveReadState,
  type EntryReadStateV1,
} from "@/lib/entryReadStateStorage";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";

export type ReadRouteContextValue = {
  selectedFolderUri: string | null;
  setSelectedFolderUri: (uri: string | null) => void;
  articleListFilter: ArticleListFilter;
  setArticleListFilter: (filter: ArticleListFilter) => void;
  markEntryRead: (entryId: string) => void;
  markEntryUnread: (entryId: string) => void;
  markEntriesRead: (entryIds: string[]) => void;
  markEntriesUnread: (entryIds: string[]) => void;
  isEntryRead: (entryId: string) => boolean;
};

const ReadRouteContext = createContext<ReadRouteContextValue | null>(null);

export function ReadRouteProvider({ children }: { children: ReactNode }) {
  const [selectedFolderUri, setSelectedFolderUri] = useState<string | null>(null);
  const [readMap, setReadMap] = useState<EntryReadStateV1>({});
  const [articleListFilter, setArticleListFilter] =
    useState<ArticleListFilter>("all");
  const pdsClient = usePDSClient();

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
    (entryId: string) => {
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
        return next;
      });
    },
    [pdsClient]
  );

  const markEntryUnread = useCallback(
    (entryId: string) => {
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
        return next;
      });
    },
    [pdsClient]
  );

  const markEntriesRead = useCallback(
    (entryIds: string[]) => {
      if (entryIds.length === 0) return;
      const unique = [...new Set(entryIds)];
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
        if (typeof window !== "undefined") {
          saveReadState(window.localStorage, next);
        }
        if (pdsClient) {
          for (const id of toSync) {
            void pdsClient.putEntryReadState(id, readAt).catch(() => {
              /* best-effort sync */
            });
          }
        }
        return next;
      });
    },
    [pdsClient]
  );

  const markEntriesUnread = useCallback(
    (entryIds: string[]) => {
      if (entryIds.length === 0) return;
      const unique = [...new Set(entryIds)];
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
        return next;
      });
    },
    [pdsClient]
  );

  const isEntryRead = useCallback(
    (entryId: string) => {
      return Boolean(readMap[entryId]);
    },
    [readMap]
  );

  const value = useMemo(
    (): ReadRouteContextValue => ({
      selectedFolderUri,
      setSelectedFolderUri,
      articleListFilter,
      setArticleListFilter,
      isEntryRead,
      markEntryRead,
      markEntryUnread,
      markEntriesRead,
      markEntriesUnread,
    }),
    [
      selectedFolderUri,
      articleListFilter,
      isEntryRead,
      markEntryRead,
      markEntryUnread,
      markEntriesRead,
      markEntriesUnread,
    ]
  );

  return (
    <ReadRouteContext.Provider value={value}>{children}</ReadRouteContext.Provider>
  );
}

export function useReadRoute(): ReadRouteContextValue {
  const ctx = useContext(ReadRouteContext);
  if (!ctx) {
    throw new Error("useReadRoute must be used within ReadRouteProvider");
  }
  return ctx;
}
