"use client";

import { useQuery } from "@tanstack/react-query";
import { useAuth } from "./useAuth";
import { createOAuthBskyAgent } from "@/lib/atprotoClient";

export const VIEWER_PROFILE_QUERY_KEY = (did: string) =>
  ["viewerProfile", did] as const;

/**
 * Loads the signed-in user's Bluesky profile (avatar, display name, handle).
 */
export function useViewerProfile() {
  const { session, getOAuthSession } = useAuth();
  const did = session?.did ?? null;

  return useQuery({
    queryKey: VIEWER_PROFILE_QUERY_KEY(did ?? ""),
    queryFn: async () => {
      const oauthSession = getOAuthSession();
      if (!did || !oauthSession) return null;
      const agent = createOAuthBskyAgent(oauthSession);
      const res = await agent.api.app.bsky.actor.getProfile({ actor: did });
      return res.data;
    },
    enabled: !!did && !!session,
    staleTime: 5 * 60_000,
  });
}
