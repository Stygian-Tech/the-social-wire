"use client";

import { useSyncExternalStore } from "react";

const subscribe = () => () => {};

/** False for SSR and the first hydration render, then true in the browser. */
export function useClientHydrated(): boolean {
  return useSyncExternalStore(subscribe, () => true, () => false);
}
