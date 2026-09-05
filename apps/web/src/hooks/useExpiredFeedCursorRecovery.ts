"use client";

import { useEffect, useRef } from "react";
import { isExpiredFeedCursor, refreshExpiredFeedCursor } from "@/lib/feedResponseError";

/** Restart the whole generation once per failed request, never append a new first page. */
export function useExpiredFeedCursorRecovery(
  error: unknown,
  refresh: () => Promise<unknown>,
  enabled: boolean,
): void {
  const attemptedError = useRef<unknown>(null);
  useEffect(() => {
    if (!enabled || !isExpiredFeedCursor(error) || attemptedError.current === error) return;
    attemptedError.current = error;
    void refreshExpiredFeedCursor(error, refresh).catch(() => {
      // Keep existing rows and surface the normal refresh error for an explicit retry.
    });
  }, [enabled, error, refresh]);
}
