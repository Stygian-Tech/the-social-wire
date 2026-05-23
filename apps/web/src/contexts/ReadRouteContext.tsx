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
import { useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { usePDSClient } from "@/hooks/usePDSClient";
import {
  loadReadState,
  mergeReadStateMaps,
  saveReadState,
  type EntryReadStateV1,
} from "@/lib/entryReadStateStorage";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import type { PublicationTab } from "@/components/AppSidebar/appSidebarConstants";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import {
  loadSidebarPublicationTab,
  saveSidebarPublicationTab,
} from "@/lib/sidebarPublicationTabStorage";
import {
  applyBulkPublicationUnreadCountDeltas,
  applyPublicationUnreadCountDelta,
  bulkReadDeltasForPublications,
  bulkUnreadDeltasForPublications,
} from "@/lib/optimisticUnreadCounts";

export type MarkEntryReadOptions = {
  publicationId?: string;
};

export type MarkEntriesReadOptions = {
  publications?: DiscoveredPublication[];
};

export type ReadRouteContextValue = {
  selectedFolderUri: string | null;
  setSelectedFolderUri: (uri: string | null) => void;
  articleListFilter: ArticleListFilter;
  setArticleListFilter: (filter: ArticleListFilter) => void;
  publicationTab: PublicationTab;
  setPublicationTab: (tab: PublicationTab) => void;
  markEntryRead: (entryId: string, options?: MarkEntryReadOptions) => void;
  markEntryUnread: (entryId: string, options?: MarkEntryReadOptions) => void;
  markEntriesRead: (entryIds: string[], options?: MarkEntriesReadOptions) => void;
  markEntriesUnread: (entryIds: string[], options?: MarkEntriesReadOptions) => void;
  isEntryRead: (entryId: string) => boolean;
};

const ReadRouteContext = createContext<ReadRouteContextValue | null>(null);

export function ReadRouteProvider({ children }: { children: ReactNode }) {
  const [selectedFolderUri, setSelectedFolderUri] = useState<string | null>(null);
  const [readMap, setReadMap] = useState<EntryReadStateV1>({});
  const [articleListFilter, setArticleListFilter] =
    useState<ArticleListFilter>("all");
  const [publicationTab, setPublicationTabState] = useState<PublicationTab>(
    () => {
      if (typeof window === "undefined") return "subscribed";
      return loadSidebarPublicationTab(window.localStorage);
    }
  );
  const pdsClient = usePDSClient();
  const queryClient = useQueryClient();
  const { session } = useAuth();
  const viewerDid = session?.did;

  const setPublicationTab = useCallback((tab: PublicationTab) => {
    setPublicationTabState(tab);
    if (typeof window !== "undefined") {
      saveSidebarPublicationTab(window.localStorage, tab);
    }
  }, []);

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
          // Defer React Query writes so we do not re-render subscribers while
          // React is still committing the readMap update.
          queueMicrotask(() => {
            applyPublicationUnreadCountDelta(
              queryClient,
              viewerDid,
              options.publicationId!,
              -1
            );
          });
        }
        return next;
      });
    },
    [pdsClient, queryClient, viewerDid]
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
          queueMicrotask(() => {
            applyPublicationUnreadCountDelta(
              queryClient,
              viewerDid,
              options.publicationId!,
              1
            );
          });
        }
        return next;
      });
    },
    [pdsClient, queryClient, viewerDid]
  );

  const markEntriesRead = useCallback(
    (entryIds: string[], options?: MarkEntriesReadOptions) => {
      if (entryIds.length === 0) return;
      const unique = [...new Set(entryIds)];
      const bulkDeltasRef: { current: Map<string, number> | null } = {
        current: null,
      };
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
        if (viewerDid && options?.publications?.length) {
          bulkDeltasRef.current = bulkReadDeltasForPublications(
            queryClient,
            options.publications,
            (entryId) => !prev[entryId]
          );
        }
        return next;
      });
      if (viewerDid && bulkDeltasRef.current && bulkDeltasRef.current.size > 0) {
        applyBulkPublicationUnreadCountDeltas(
          queryClient,
          viewerDid,
          bulkDeltasRef.current
        );
      }
    },
    [pdsClient, queryClient, viewerDid]
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
      if (viewerDid && bulkDeltasRef.current && bulkDeltasRef.current.size > 0) {
        applyBulkPublicationUnreadCountDeltas(
          queryClient,
          viewerDid,
          bulkDeltasRef.current
        );
      }
    },
    [pdsClient, queryClient, viewerDid]
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
      publicationTab,
      setPublicationTab,
      isEntryRead,
      markEntryRead,
      markEntryUnread,
      markEntriesRead,
      markEntriesUnread,
    }),
    [
      selectedFolderUri,
      articleListFilter,
      publicationTab,
      isEntryRead,
      markEntryRead,
      markEntryUnread,
      markEntriesRead,
      markEntriesUnread,
      setPublicationTab,
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
