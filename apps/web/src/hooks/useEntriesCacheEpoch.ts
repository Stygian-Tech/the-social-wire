"use client";

import { useEffect, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";

function isEntriesListQueryKey(key: unknown): boolean {
  return Array.isArray(key) && key[0] === "entries";
}

/**
 * Increments when any `ENTRIES_QUERY_KEY` query cache updates (mirrors {@link useSidebarUnreadCounts}).
 */
export function useEntriesCacheEpoch(): number {
  const queryClient = useQueryClient();
  const [epoch, setEpoch] = useState(0);
  const bumpRafRef = useRef<number | null>(null);

  useEffect(() => {
    const unsub = queryClient.getQueryCache().subscribe((event) => {
      const key = event?.query?.queryKey;
      if (!isEntriesListQueryKey(key)) return;
      if (bumpRafRef.current != null) return;

      const runBump = () => {
        bumpRafRef.current = null;
        setEpoch((e) => e + 1);
      };

      bumpRafRef.current =
        typeof requestAnimationFrame === "function"
          ? requestAnimationFrame(runBump)
          : (setTimeout(runBump, 0) as unknown as number);
    });

    return () => {
      unsub();
      if (bumpRafRef.current != null) {
        if (typeof cancelAnimationFrame === "function") {
          cancelAnimationFrame(bumpRafRef.current);
        } else if (typeof clearTimeout === "function") {
          clearTimeout(bumpRafRef.current);
        }
        bumpRafRef.current = null;
      }
    };
  }, [queryClient]);

  return epoch;
}
