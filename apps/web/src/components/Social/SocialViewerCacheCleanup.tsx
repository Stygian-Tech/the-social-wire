"use client";

import { useEffect, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";

export function SocialViewerCacheCleanup() {
  const { session } = useAuth();
  const queryClient = useQueryClient();
  const previousViewerDid = useRef(session?.did);
  useEffect(() => {
    const previous = previousViewerDid.current;
    if (previous && previous !== session?.did) {
      void queryClient.cancelQueries({ queryKey: ["blueskySocial", previous] });
      queryClient.removeQueries({ queryKey: ["blueskySocial", previous] });
    }
    previousViewerDid.current = session?.did;
  }, [queryClient, session?.did]);
  return null;
}
