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
import { useShowHiddenFolder } from "@/hooks/useShowHiddenFolder";
import {
  loadReadState,
  mergeReadStateMaps,
  saveReadState,
  type EntryReadStateV1,
} from "@/lib/entryReadStateStorage";
import { PSEUDO_FOLDER_HIDDEN_URI } from "@/lib/pdsClient";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";

export type ReadRouteContextValue = {
  selectedFolderUri: string | null;
  setSelectedFolderUri: (uri: string | null) => void;
  /** When the Hidden Publications folder is selected; also drives read UI + writes. */
  isHiddenFolderContext: boolean;
  /** User preference for the entry list; use {@link effectiveArticleListFilter} for the gated value. */
  articleListFilter: ArticleListFilter;
  setArticleListFilter: (filter: ArticleListFilter) => void;
  /** `all` when Hidden Publications is selected; otherwise {@link articleListFilter}. */
  effectiveArticleListFilter: ArticleListFilter;
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
  const { showHiddenFolder } = useShowHiddenFolder();
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

  const resolvedSelectedFolderUri =
    !showHiddenFolder && selectedFolderUri === PSEUDO_FOLDER_HIDDEN_URI
      ? null
      : selectedFolderUri;

  const isHiddenFolderContext =
    resolvedSelectedFolderUri === PSEUDO_FOLDER_HIDDEN_URI;

  const effectiveArticleListFilter: ArticleListFilter = isHiddenFolderContext
    ? "all"
    : articleListFilter;

  const markEntryRead = useCallback(
    (entryId: string) => {
      if (isHiddenFolderContext) return;
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
    [isHiddenFolderContext, pdsClient]
  );

  const markEntryUnread = useCallback(
    (entryId: string) => {
      if (isHiddenFolderContext) return;
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
    [isHiddenFolderContext, pdsClient]
  );

  const markEntriesRead = useCallback(
    (entryIds: string[]) => {
      if (isHiddenFolderContext || entryIds.length === 0) return;
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
    [isHiddenFolderContext, pdsClient]
  );

  const markEntriesUnread = useCallback(
    (entryIds: string[]) => {
      if (isHiddenFolderContext || entryIds.length === 0) return;
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
    [isHiddenFolderContext, pdsClient]
  );

  const isEntryRead = useCallback(
    (entryId: string) => {
      if (isHiddenFolderContext) return false;
      return Boolean(readMap[entryId]);
    },
    [readMap, isHiddenFolderContext]
  );

  const value = useMemo(
    (): ReadRouteContextValue => ({
      selectedFolderUri: resolvedSelectedFolderUri,
      setSelectedFolderUri,
      isHiddenFolderContext,
      articleListFilter,
      setArticleListFilter,
      effectiveArticleListFilter,
      isEntryRead,
      markEntryRead,
      markEntryUnread,
      markEntriesRead,
      markEntriesUnread,
    }),
    [
      resolvedSelectedFolderUri,
      isHiddenFolderContext,
      articleListFilter,
      effectiveArticleListFilter,
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
