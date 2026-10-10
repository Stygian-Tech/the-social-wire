"use client";

import { useSyncExternalStore } from "react";

const DESKTOP_RAIL_QUERY = "(min-width: 1024px)";
function subscribe(onChange: () => void) {
  const media = window.matchMedia(DESKTOP_RAIL_QUERY);
  media.addEventListener("change", onChange);
  return () => media.removeEventListener("change", onChange);
}
function getSnapshot() { return window.matchMedia(DESKTOP_RAIL_QUERY).matches; }
function getServerSnapshot() { return false; }
/** Keep the viewport-fixed rail outside the sidebar's backdrop-filter container. */
export function useDesktopPublicationRail() {
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
}
