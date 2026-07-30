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
import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";

type ReadSidebarScopeValue = {
  activeFeedScope: {
    publications: DiscoveredPublication[];
    gatewayScope: GatewayMarkAllReadScope | null;
    displayName: string;
  };
  setActiveFeedScope: Dispatch<
    SetStateAction<{
      publications: DiscoveredPublication[];
      gatewayScope: GatewayMarkAllReadScope | null;
      displayName: string;
    }>
  >;
};

const ReadSidebarScopeContext = createContext<ReadSidebarScopeValue | null>(
  null
);

export function ReadSidebarScopeProvider({ children }: { children: ReactNode }) {
  const [activeFeedScope, setActiveFeedScope] = useState<{
    publications: DiscoveredPublication[];
    gatewayScope: GatewayMarkAllReadScope | null;
    displayName: string;
  }>({
    publications: [],
    gatewayScope: null,
    displayName: "",
  });

  const value = useMemo(
    (): ReadSidebarScopeValue => ({
      activeFeedScope,
      setActiveFeedScope,
    }),
    [activeFeedScope, setActiveFeedScope]
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
