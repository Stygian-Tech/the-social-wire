"use client";

import { useEffect, useState } from "react";

/** Optional cached decoration must not run before this feed's story frame. */
export function useFeedDecorationsReady(scope: string, hasStories: boolean) {
  const [releaseState, setReleaseState] = useState({ scope, ready: false });
  if (releaseState.scope !== scope) setReleaseState({ scope, ready: false });
  useEffect(() => {
    if (!hasStories) return;
    let active = true;
    let scheduled = false;
    let idle: number | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const release = () => {
      if (!active || scheduled) return;
      scheduled = true;
      const complete = () => { if (active) setReleaseState({ scope, ready: true }); };
      if (typeof window.requestIdleCallback === "function") {
        idle = window.requestIdleCallback(complete, { timeout: 1_000 });
      } else timer = setTimeout(complete, 0);
    };
    const observer = typeof PerformanceObserver === "function" ? new PerformanceObserver(list => {
      if (list.getEntries().some(entry => entry.name === "socialwire.feed.first-content" &&
        (entry as PerformanceMeasure).detail?.scope === scope)) release();
    }) : undefined;
    observer?.observe({ entryTypes: ["measure"] });
    // Empty/error/unsupported performance environments still expose controls after a bounded wait.
    const fallback = setTimeout(release, 8_000);
    return () => {
      active = false;
      observer?.disconnect();
      clearTimeout(fallback);
      if (timer !== undefined) clearTimeout(timer);
      if (idle !== undefined) window.cancelIdleCallback(idle);
    };
  }, [scope, hasStories]);
  return !hasStories || (releaseState.scope === scope && releaseState.ready);
}
