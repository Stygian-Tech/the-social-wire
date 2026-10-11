"use client";
import { useLayoutEffect, useMemo, useRef, useState } from "react";
import { useAuth } from "./useAuth";
import { getStoredOAuthDid } from "@/lib/auth";

export function usePodcastClipAccount() {
  const { session, getOAuthSession } = useAuth();
  const viewer = session?.did ?? null;
  const epoch = useRef(0);
  const [revision, redraw] = useState(0);
  const generation = useMemo(() => ({ viewer, revision }), [viewer, revision]);
  useLayoutEffect(() => {
    const invalidate = (event: Event) => {
      if (event.type === "storage" && (event as StorageEvent).key !== "@@atproto/oauth-client-browser(sub)") return;
      epoch.current += 1; redraw(epoch.current);
    };
    window.addEventListener("storage", invalidate);
    window.addEventListener("the-social-wire.oauth-viewer-changed", invalidate);
    return () => { window.removeEventListener("storage", invalidate); window.removeEventListener("the-social-wire.oauth-viewer-changed", invalidate); };
  }, []);
  const current = useRef({ viewer, generation, mounted: true });
  useLayoutEffect(() => {
    current.current = { viewer, generation, mounted: true };
    return () => { current.current.mounted = false; };
  }, [viewer, generation]);
  const assertCurrentAccount = () => {
    if (!viewer || epoch.current !== revision || !current.current.mounted || current.current.generation !== generation ||
      getOAuthSession()?.did !== viewer || getStoredOAuthDid() !== viewer)
      throw new Error("Account Is Loading. Please Retry.");
  };
  const requireSession = () => { assertCurrentAccount(); return getOAuthSession()!; };
  return { viewer, requireSession, assertCurrentAccount, getOAuthSession };
}
