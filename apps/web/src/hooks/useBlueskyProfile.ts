"use client";

import { useQuery } from "@tanstack/react-query";
import type { ModerationOpts } from "@atproto/api";
import { useAuth } from "./useAuth";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";
import { isSocialProfileActor } from "@/lib/socialProfileNavigation";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function useBlueskyProfile(actor: string | null | undefined, moderation?: ModerationOpts) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  return useQuery({
    queryKey: ["blueskySocial", session?.did ?? "", "profile", oauthSessionReloadSeq, actor, moderation?.prefs.labelers.map(labeler => labeler.did)],
    enabled: isSocialProfileActor(actor) && !!session && moderation?.userDid === session.did,
    queryFn: async ({ signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      if (oauth.did !== session?.did || moderation?.userDid !== oauth.did || !actor) throw new Error("Your account changed. Please reload this profile.");
      const agent = createAuthenticatedAppViewAgent(oauth);
      agent.configureLabelers(moderation.prefs.labelers.map(labeler => labeler.did));
      const result = await agent.app.bsky.actor.getProfile({ actor }, { signal });
      return result.data;
    },
    retry: false,
    staleTime: 30_000,
  });
}
