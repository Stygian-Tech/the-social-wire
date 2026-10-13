"use client";

import { useEffect, useRef } from "react";

/** Measure the rendered content frame, separately from network/query completion. */
export function useFeedFirstContentTiming(scope: string, ready: boolean, cacheHit: boolean) {
  const sample = useRef({ scope: "", startedAt: 0 });
  useEffect(() => { sample.current = { scope, startedAt: performance.now() }; }, [scope]);
  const recordedScope = useRef<string | null>(null);
  useEffect(() => {
    if (!ready || recordedScope.current === scope || typeof requestAnimationFrame !== "function") return;
    const captured = sample.current;
    let secondFrame = 0;
    const firstFrame = requestAnimationFrame(() => {
      secondFrame = requestAnimationFrame(() => {
        if (recordedScope.current === scope) return;
        recordedScope.current = scope;
        // Keep one current sample; PerformanceObserver still receives every completed frame.
        performance.clearMeasures("socialwire.feed.first-content");
        performance.measure("socialwire.feed.first-content", {
          start: captured.startedAt,
          end: performance.now(),
          detail: { scope, cacheState: cacheHit ? "hit" : "miss" },
        });
      });
    });
    return () => { cancelAnimationFrame(firstFrame); cancelAnimationFrame(secondFrame); };
  }, [scope, ready, cacheHit]);
}
