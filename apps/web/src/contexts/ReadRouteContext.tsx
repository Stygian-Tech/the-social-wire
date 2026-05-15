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
import { useShowHiddenFolder } from "@/hooks/useShowHiddenFolder";
import {
  loadReadState,
  saveReadState,
  type EntryReadStateV1,
} from "@/lib/entryReadStateStorage";
import { PSEUDO_FOLDER_HIDDEN_URI } from "@/lib/pdsClient";

export type ReadRouteContextValue = {
  selectedFolderUri: string | null;
  setSelectedFolderUri: (uri: string | null) => void;
  /** When the Hidden Publications folder is selected; also drives read UI + writes. */
  isHiddenFolderContext: boolean;
  markEntryRead: (entryId: string) => void;
  isEntryRead: (entryId: string) => boolean;
};

const ReadRouteContext = createContext<ReadRouteContextValue | null>(null);

export function ReadRouteProvider({ children }: { children: ReactNode }) {
  const [selectedFolderUri, setSelectedFolderUri] = useState<string | null>(null);
  const [readMap, setReadMap] = useState<EntryReadStateV1>({});
  const { showHiddenFolder } = useShowHiddenFolder();

  useEffect(() => {
    if (typeof window === "undefined") return;
    queueMicrotask(() => {
      setReadMap(loadReadState(window.localStorage));
    });
  }, []);

  const resolvedSelectedFolderUri =
    !showHiddenFolder && selectedFolderUri === PSEUDO_FOLDER_HIDDEN_URI
      ? null
      : selectedFolderUri;

  const isHiddenFolderContext =
    resolvedSelectedFolderUri === PSEUDO_FOLDER_HIDDEN_URI;

  const markEntryRead = useCallback(
    (entryId: string) => {
      if (isHiddenFolderContext) return;
      setReadMap((prev) => {
        if (prev[entryId]) return prev;
        const next = { ...prev, [entryId]: new Date().toISOString() };
        if (typeof window !== "undefined") {
          saveReadState(window.localStorage, next);
        }
        return next;
      });
    },
    [isHiddenFolderContext]
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
      isEntryRead,
      markEntryRead,
    }),
    [resolvedSelectedFolderUri, isHiddenFolderContext, isEntryRead, markEntryRead]
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
