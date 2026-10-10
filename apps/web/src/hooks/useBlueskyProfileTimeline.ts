"use client";

import { useInfiniteQuery } from "@tanstack/react-query";
import type { ModerationOpts } from "@atproto/api";
import { useAuth } from "@/hooks/useAuth";
import { getBlueskyProfilePage, type ProfileSection } from "@/lib/blueskyProfileClient";
import { nextSocialCursor } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function useBlueskyProfileTimeline(tab: ProfileSection, moderation: ModerationOpts | undefined) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  return useInfiniteQuery({
    queryKey: ["blueskySocial", session?.did ?? "", "profileTimeline", oauthSessionReloadSeq, tab, moderation?.prefs.labelers.map(labeler => labeler.did)],
    enabled: !!session && moderation?.userDid === session.did,
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam, signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      if (oauth.did !== session?.did || !moderation) throw new Error("Your account changed. Please reload this feed.");
      return getBlueskyProfilePage({ session: oauth, tab, moderation, cursor: pageParam, signal });
    },
    getNextPageParam: (lastPage, _pages, _lastParam, pageParams) => nextSocialCursor(lastPage, pageParams),
    retry: false,
    staleTime: 30_000,
  });
}
