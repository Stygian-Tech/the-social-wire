"use client";

import { useLayoutEffect, useRef } from "react";
import { rememberSocialFeedScroll, restoreSocialFeedScroll } from "@/lib/socialFeedScroll";

export function useSocialFeedScroll(did: string | undefined, feed: string, ready: boolean) {
  const container = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const node = container.current;
    if (!node || !did || !ready) return;
    restoreSocialFeedScroll(did, feed, node);
    // Capture at departure, avoiding a layout scan on every scrolling frame.
    return () => rememberSocialFeedScroll(did, feed, node);
  }, [did, feed, ready]);
  return container;
}
