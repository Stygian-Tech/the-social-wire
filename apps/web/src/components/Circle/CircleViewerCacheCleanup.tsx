"use client";

import { useEffect, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";

import { useAuth } from "@/hooks/useAuth";
import { clearCircleViewerQueries } from "@/lib/circleQueryCache";

export function CircleViewerCacheCleanup() {
  const { session } = useAuth();
  const queryClient = useQueryClient();
  const previousViewerDid = useRef(session?.did);

  useEffect(() => {
    const previous = previousViewerDid.current;
    const current = session?.did;
    if (previous && previous !== current) {
      clearCircleViewerQueries(queryClient, previous);
    }
    previousViewerDid.current = current;
  }, [queryClient, session?.did]);

  return null;
}
