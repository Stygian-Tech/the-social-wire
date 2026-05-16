"use client";

import {
  createContext,
  useContext,
  useMemo,
  useState,
  type Dispatch,
  type ReactNode,
  type SetStateAction,
} from "react";

import type { DiscoveredPublication } from "@/lib/atprotoClient";

type ReadSidebarScopeValue = {
  publicationsInSidebarTab: DiscoveredPublication[];
  setPublicationsInSidebarTab: Dispatch<
    SetStateAction<DiscoveredPublication[]>
  >;
};

const ReadSidebarScopeContext = createContext<ReadSidebarScopeValue | null>(
  null
);

export function ReadSidebarScopeProvider({ children }: { children: ReactNode }) {
  const [publicationsInSidebarTab, setPublicationsInSidebarTab] = useState<
    DiscoveredPublication[]
  >([]);

  const value = useMemo(
    (): ReadSidebarScopeValue => ({
      publicationsInSidebarTab,
      setPublicationsInSidebarTab,
    }),
    [publicationsInSidebarTab]
  );

  return (
    <ReadSidebarScopeContext.Provider value={value}>
      {children}
    </ReadSidebarScopeContext.Provider>
  );
}

export function useReadSidebarScope(): ReadSidebarScopeValue {
  const ctx = useContext(ReadSidebarScopeContext);
  if (!ctx) {
    throw new Error(
      "useReadSidebarScope must be used within ReadSidebarScopeProvider"
    );
  }
  return ctx;
}

/** When outside `/read` shell, returns null (sidebar sync / header actions disabled). */
export function useReadSidebarScopeOptional(): ReadSidebarScopeValue | null {
  return useContext(ReadSidebarScopeContext);
}
