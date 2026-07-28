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
import { useAuth } from "@/hooks/useAuth";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import type { PublicationTab } from "@/components/AppSidebar/appSidebarConstants";
import {
  loadSidebarPublicationTab,
  saveSidebarPublicationTab,
} from "@/lib/sidebarPublicationTabStorage";
import {
  defaultSidebarExpandedKeys,
  folderExpandKey,
  loadSidebarExpandedKeys,
  migrateLegacyFolderUriExpandKeys,
  saveSidebarExpandedKeys,
  SIDEBAR_FOLDER_EXPAND_MIGRATE_EVENT,
} from "@/lib/sidebarExpandedKeysStorage";

export type SidebarChromeContextValue = {
  selectedFolderUri: string | null;
  setSelectedFolderUri: (uri: string | null) => void;
  articleListFilter: ArticleListFilter;
  setArticleListFilter: (filter: ArticleListFilter) => void;
  isArticleListColumnOpen: boolean;
  setIsArticleListColumnOpen: (isOpen: boolean) => void;
  publicationTab: PublicationTab;
  setPublicationTab: (tab: PublicationTab) => void;
  sidebarExpandedKeys: Set<string>;
  toggleSidebarExpandedKey: (key: string) => void;
  syncSidebarFolderExpandKeys: (folderUris: string[]) => void;
};

const SidebarChromeContext = createContext<SidebarChromeContextValue | null>(
  null
);

const ANONYMOUS_EXPANDED_KEYS_KEY = "__anonymous__";

function loadInitialPublicationTab(): PublicationTab {
  return "subscribed";
}

function loadExpandedKeysForViewer(did: string): Set<string> {
  return loadSidebarExpandedKeys(window.localStorage, did);
}

export function SidebarChromeProvider({ children }: { children: ReactNode }) {
  const [selectedFolderUri, setSelectedFolderUri] = useState<string | null>(null);
  const [articleListFilter, setArticleListFilter] =
    useState<ArticleListFilter>("all");
  const [isArticleListColumnOpen, setIsArticleListColumnOpen] = useState(true);
  const [publicationTab, setPublicationTabState] =
    useState<PublicationTab>(loadInitialPublicationTab);
  const [sidebarExpandedKeysByViewer, setSidebarExpandedKeysByViewer] =
    useState<Record<string, Set<string>>>({});
  const { session } = useAuth();
  const viewerDid = session?.did;
  const sidebarExpandedKeysStateKey = viewerDid ?? ANONYMOUS_EXPANDED_KEYS_KEY;

  const sidebarExpandedKeys = useMemo(
    () =>
      sidebarExpandedKeysByViewer[sidebarExpandedKeysStateKey] ??
      defaultSidebarExpandedKeys(),
    [sidebarExpandedKeysByViewer, sidebarExpandedKeysStateKey]
  );

  useEffect(() => {
    if (typeof window === "undefined") return;
    queueMicrotask(() => {
      setPublicationTabState(loadSidebarPublicationTab(window.localStorage));
    });
  }, []);

  useEffect(() => {
    if (typeof window === "undefined" || !viewerDid) return;
    queueMicrotask(() => {
      setSidebarExpandedKeysByViewer((prev) => {
        if (prev[viewerDid]) return prev;
        return {
          ...prev,
          [viewerDid]: loadExpandedKeysForViewer(viewerDid),
        };
      });
    });
  }, [viewerDid]);

  const setPublicationTab = useCallback((tab: PublicationTab) => {
    setPublicationTabState(tab);
    if (typeof window !== "undefined") {
      saveSidebarPublicationTab(window.localStorage, tab);
    }
  }, []);

  useEffect(() => {
    if (typeof window === "undefined" || !viewerDid) return;
    if (!sidebarExpandedKeysByViewer[viewerDid]) return;
    saveSidebarExpandedKeys(window.localStorage, viewerDid, sidebarExpandedKeys);
  }, [viewerDid, sidebarExpandedKeysByViewer, sidebarExpandedKeys]);

  useEffect(() => {
    if (typeof window === "undefined" || !viewerDid) return;

    const onMigrate = (event: Event) => {
      const detail = (event as CustomEvent<{ did: string; oldRkey: string; newRkey: string }>)
        .detail;
      if (!detail || detail.did !== viewerDid) return;
      setSidebarExpandedKeysByViewer((prev) => {
        const current = prev[viewerDid] ?? defaultSidebarExpandedKeys();
        const oldKey = folderExpandKey(detail.oldRkey);
        if (!current.has(oldKey)) return prev;
        const next = new Set(current);
        next.delete(oldKey);
        next.add(folderExpandKey(detail.newRkey));
        return { ...prev, [viewerDid]: next };
      });
    };

    window.addEventListener(SIDEBAR_FOLDER_EXPAND_MIGRATE_EVENT, onMigrate);
    return () => {
      window.removeEventListener(SIDEBAR_FOLDER_EXPAND_MIGRATE_EVENT, onMigrate);
    };
  }, [viewerDid]);

  const toggleSidebarExpandedKey = useCallback((key: string) => {
    setSidebarExpandedKeysByViewer((prev) => {
      const current = prev[sidebarExpandedKeysStateKey] ?? sidebarExpandedKeys;
      const next = new Set(current);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return { ...prev, [sidebarExpandedKeysStateKey]: next };
    });
  }, [sidebarExpandedKeys, sidebarExpandedKeysStateKey]);

  const syncSidebarFolderExpandKeys = useCallback((folderUris: string[]) => {
    setSidebarExpandedKeysByViewer((prev) => {
      const current = prev[sidebarExpandedKeysStateKey] ?? sidebarExpandedKeys;
      const next = migrateLegacyFolderUriExpandKeys(current, folderUris);
      if (next === current) return prev;
      return { ...prev, [sidebarExpandedKeysStateKey]: next };
    });
  }, [sidebarExpandedKeys, sidebarExpandedKeysStateKey]);

  const value = useMemo(
    (): SidebarChromeContextValue => ({
      selectedFolderUri,
      setSelectedFolderUri,
      articleListFilter,
      setArticleListFilter,
      isArticleListColumnOpen,
      setIsArticleListColumnOpen,
      publicationTab,
      setPublicationTab,
      sidebarExpandedKeys,
      toggleSidebarExpandedKey,
      syncSidebarFolderExpandKeys,
    }),
    [
      selectedFolderUri,
      articleListFilter,
      isArticleListColumnOpen,
      publicationTab,
      sidebarExpandedKeys,
      toggleSidebarExpandedKey,
      syncSidebarFolderExpandKeys,
      setPublicationTab,
    ]
  );

  return (
    <SidebarChromeContext.Provider value={value}>
      {children}
    </SidebarChromeContext.Provider>
  );
}

export function useSidebarChrome(): SidebarChromeContextValue {
  const ctx = useContext(SidebarChromeContext);
  if (!ctx) {
    throw new Error("useSidebarChrome must be used within SidebarChromeProvider");
  }
  return ctx;
}
