"use client";

import { useQuery } from "@tanstack/react-query";
import type { ModerationOpts } from "@atproto/api";
import { useAuth } from "@/hooks/useAuth";
import { getBlueskyPostThread } from "@/lib/blueskyPostClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function useBlueskyPostThread(uri: string | undefined, moderation: ModerationOpts | undefined) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  return useQuery({
    queryKey: ["blueskySocial", session?.did ?? "", "thread", oauthSessionReloadSeq, uri, moderation?.prefs.labelers.map(labeler => labeler.did)],
    enabled: !!uri && !!session && moderation?.userDid === session.did,
    queryFn: ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      if (oauth.did !== session?.did || !moderation || !uri) throw new Error("Your account changed. Please reload this post.");
      return getBlueskyPostThread({ session: oauth, uri, moderation, signal });
    },
    retry: false,
    staleTime: 30_000,
  });
}
