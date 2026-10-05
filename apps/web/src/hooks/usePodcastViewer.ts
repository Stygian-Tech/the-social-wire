"use client";
import { useSyncExternalStore } from "react";
import { useAuth } from "./useAuth";
import { getStoredOAuthDid } from "@/lib/auth";
const subscribe = (listener: () => void) => {
  window.addEventListener("online", listener);
  window.addEventListener("offline", listener);
  window.addEventListener("storage", listener);
  window.addEventListener("the-social-wire.oauth-viewer-changed", listener);
  return () => {
    window.removeEventListener("online", listener);
    window.removeEventListener("offline", listener);
    window.removeEventListener("storage", listener);
    window.removeEventListener(
      "the-social-wire.oauth-viewer-changed",
      listener,
    );
  };
};
function offlineViewer(): string | null {
  if (navigator.onLine) return null;
  const did = getStoredOAuthDid();
  return did?.startsWith("did:") ? did : null;
}
/** Offline identity grants access only to this device's cache; API calls still require OAuth. */
export function usePodcastViewer(): string | null {
  const { session } = useAuth();
  const offline = useSyncExternalStore(subscribe, offlineViewer, () => null);
  return session?.did ?? offline;
}
