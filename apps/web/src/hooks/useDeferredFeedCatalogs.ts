"use client";

import { useEffect, useState } from "react";

/** Let the selected feed paint before optional navigation discovery competes for requests. */
export function useDeferredFeedCatalogs(enabled: boolean) {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    if (!enabled) return;
    let idle: number | undefined;
    let scheduled = false;
    const release = () => {
      if (scheduled) return;
      scheduled = true;
      if (typeof window.requestIdleCallback === "function") {
        idle = window.requestIdleCallback(() => setReady(true), { timeout: 2_000 });
      } else setReady(true);
    };
    const fallback = window.setTimeout(release, 8_000);
    const observer = typeof PerformanceObserver === "function" ? new PerformanceObserver(list => {
      if (list.getEntries().some(entry => entry.name === "socialwire.feed.first-content")) release();
    }) : undefined;
    observer?.observe({ entryTypes: ["measure"] });
    return () => {
      window.clearTimeout(fallback);
      observer?.disconnect();
      if (idle !== undefined) window.cancelIdleCallback(idle);
    };
  }, [enabled]);
  return enabled && ready;
}
