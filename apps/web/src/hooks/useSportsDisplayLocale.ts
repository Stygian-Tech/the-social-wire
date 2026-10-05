"use client";

import { useSyncExternalStore } from "react";

const subscribe = (onChange: () => void) => {
  window.addEventListener("languagechange", onChange);
  return () => window.removeEventListener("languagechange", onChange);
};
const browserLocale = () => navigator.languages?.[0] || navigator.language || "en-US";

/** A stable server snapshot prevents browser locale differences from breaking hydration. */
export function useSportsDisplayLocale(): string {
  return useSyncExternalStore(subscribe, browserLocale, () => "en-US");
}
