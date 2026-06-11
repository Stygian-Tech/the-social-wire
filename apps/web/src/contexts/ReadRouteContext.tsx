"use client";

import { type ReactNode } from "react";

import { ReadStateProvider, useReadState } from "@/contexts/ReadStateContext";
import {
  SidebarChromeProvider,
  useSidebarChrome,
} from "@/contexts/SidebarChromeContext";

export type {
  MarkEntryReadOptions,
  MarkEntriesReadOptions,
} from "@/contexts/ReadStateContext";

export type ReadRouteContextValue = ReturnType<typeof useReadRoute>;

export function ReadRouteProvider({ children }: { children: ReactNode }) {
  return (
    <ReadStateProvider>
      <SidebarChromeProvider>{children}</SidebarChromeProvider>
    </ReadStateProvider>
  );
}

/** Combined read state + sidebar chrome (backward compatible). */
export function useReadRoute() {
  const readState = useReadState();
  const chrome = useSidebarChrome();
  return { ...readState, ...chrome };
}
