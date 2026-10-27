"use client";

import { useEffect, useEffectEvent } from "react";
import { awaitWithAbort } from "@/lib/awaitWithAbort";

/** One visible-tab refresh at a time, cancelled when its account/feed leaves. */
export function useVisibleFeedRefresh(
  scope: string | null,
  refresh: (signal: AbortSignal) => Promise<unknown>,
  intervalMs = 45_000,
) {
  const refreshCurrent = useEffectEvent(refresh);
  useEffect(() => {
    if (!scope) return;
    const lifetime = new AbortController();
    let pending = false;
    const run = async () => {
      if (pending || lifetime.signal.aborted || document.visibilityState !== "visible") return;
      pending = true;
      try {
        const signal = AbortSignal.any([lifetime.signal, AbortSignal.timeout(30_000)]);
        await awaitWithAbort(refreshCurrent(signal), signal);
      } catch {
        // Background failures keep the current rows; explicit refresh exposes errors.
      } finally {
        pending = false;
      }
    };
    const interval = window.setInterval(() => void run(), intervalMs);
    const onVisible = () => void run();
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", onVisible);
    return () => {
      lifetime.abort();
      window.clearInterval(interval);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", onVisible);
    };
  }, [scope, intervalMs]);
}
