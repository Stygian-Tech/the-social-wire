"use client";

import { useEffect, useLayoutEffect, useRef } from "react";

/** Require two uninterrupted seconds of visible, loaded content before reading it. */
export function usePageReadDelay(key: string | undefined, enabled: boolean, markRead: () => void) {
  const callback = useRef(markRead);
  const attempted = useRef<string | undefined>(undefined);
  useLayoutEffect(() => { callback.current = markRead; });

  useEffect(() => {
    if (!key || !enabled || attempted.current === key) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    function cancel() { if (timer !== undefined) clearTimeout(timer); timer = undefined; }
    function schedule() {
      cancel();
      if (document.visibilityState !== "visible" || attempted.current === key) return;
      timer = setTimeout(() => {
        if (document.visibilityState !== "visible") return;
        attempted.current = key;
        callback.current();
      }, 2_000);
    }
    document.addEventListener("visibilitychange", schedule);
    schedule();
    return () => { cancel(); document.removeEventListener("visibilitychange", schedule); };
  }, [key, enabled]);
}
