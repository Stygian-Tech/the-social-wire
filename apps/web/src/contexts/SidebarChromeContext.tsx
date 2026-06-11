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
  publicationTab: PublicationTab;
  setPublicationTab: (tab: PublicationTab) => void;
  sidebarExpandedKeys: Set<string>;
  toggleSidebarExpandedKey: (key: string) => void;
  syncSidebarFolderExpandKeys: (folderUris: string[]) => void;
};

const SidebarChromeContext = createContext<SidebarChromeContextValue | null>(
  null
);

export function SidebarChromeProvider({ children }: { children: ReactNode }) {
  const [selectedFolderUri, setSelectedFolderUri] = useState<string | null>(null);
  const [articleListFilter, setArticleListFilter] =
    useState<ArticleListFilter>("all");
  const [publicationTab, setPublicationTabState] = useState<PublicationTab>(
    () => {
      if (typeof window === "undefined") return "subscribed";
      return loadSidebarPublicationTab(window.localStorage);
    }
  );
  const [sidebarExpandedKeys, setSidebarExpandedKeys] = useState(
    defaultSidebarExpandedKeys
  );
  const [sidebarExpandedKeysDid, setSidebarExpandedKeysDid] = useState<
    string | undefined
  >(undefined);
  const { session } = useAuth();
  const viewerDid = session?.did;

  if (
    typeof window !== "undefined" &&
    viewerDid &&
    viewerDid !== sidebarExpandedKeysDid
  ) {
    setSidebarExpandedKeysDid(viewerDid);
    setSidebarExpandedKeys(loadSidebarExpandedKeys(window.localStorage, viewerDid));
  }

  const setPublicationTab = useCallback((tab: PublicationTab) => {
    setPublicationTabState(tab);
    if (typeof window !== "undefined") {
      saveSidebarPublicationTab(window.localStorage, tab);
    }
  }, []);

  useEffect(() => {
    if (
      typeof window === "undefined" ||
      !viewerDid ||
      viewerDid !== sidebarExpandedKeysDid
    ) {
      return;
    }
    saveSidebarExpandedKeys(window.localStorage, viewerDid, sidebarExpandedKeys);
  }, [viewerDid, sidebarExpandedKeysDid, sidebarExpandedKeys]);

  useEffect(() => {
    if (typeof window === "undefined" || !viewerDid) return;

    const onMigrate = (event: Event) => {
      const detail = (event as CustomEvent<{ did: string; oldRkey: string; newRkey: string }>)
        .detail;
      if (!detail || detail.did !== viewerDid) return;
      setSidebarExpandedKeys((prev) => {
        const oldKey = folderExpandKey(detail.oldRkey);
        if (!prev.has(oldKey)) return prev;
        const next = new Set(prev);
        next.delete(oldKey);
        next.add(folderExpandKey(detail.newRkey));
        return next;
      });
    };

    window.addEventListener(SIDEBAR_FOLDER_EXPAND_MIGRATE_EVENT, onMigrate);
    return () => {
      window.removeEventListener(SIDEBAR_FOLDER_EXPAND_MIGRATE_EVENT, onMigrate);
    };
  }, [viewerDid]);

  const toggleSidebarExpandedKey = useCallback((key: string) => {
    setSidebarExpandedKeys((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }, []);

  const syncSidebarFolderExpandKeys = useCallback((folderUris: string[]) => {
    setSidebarExpandedKeys((prev) =>
      migrateLegacyFolderUriExpandKeys(prev, folderUris)
    );
  }, []);

  const value = useMemo(
    (): SidebarChromeContextValue => ({
      selectedFolderUri,
      setSelectedFolderUri,
      articleListFilter,
      setArticleListFilter,
      publicationTab,
      setPublicationTab,
      sidebarExpandedKeys,
      toggleSidebarExpandedKey,
      syncSidebarFolderExpandKeys,
    }),
    [
      selectedFolderUri,
      articleListFilter,
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
