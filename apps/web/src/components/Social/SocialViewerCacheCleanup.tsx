"use client";

import { useEffect, useRef } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";

export function SocialViewerCacheCleanup() {
  const { session, oauthSessionReloadSeq } = useAuth();
  const queryClient = useQueryClient();
  const previousViewerDid = useRef(session?.did);
  const previousSequence = useRef(oauthSessionReloadSeq);
  useEffect(() => {
    const previous = previousViewerDid.current;
    if (previous && previous !== session?.did) {
      void queryClient.cancelQueries({ queryKey: ["blueskySocial", previous] });
      queryClient.removeQueries({ queryKey: ["blueskySocial", previous] });
    }
    if (previous === session?.did && session?.did && previousSequence.current !== oauthSessionReloadSeq) {
      const queryKey = ["blueskySocial", session.did];
      // A new OAuth handle refreshes the stable cache without discarding its rows.
      void queryClient.cancelQueries({ queryKey }).then(() => queryClient.invalidateQueries({ queryKey }));
    }
    previousSequence.current = oauthSessionReloadSeq;
    previousViewerDid.current = session?.did;
  }, [queryClient, session?.did, oauthSessionReloadSeq]);
  return null;
}
