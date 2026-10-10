"use client";

import { useEffect, useRef } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { useAuth } from "@/hooks/useAuth";
import { setBlueskyPostEngagement, type SocialEngagementKind, type SocialPostEngagement } from "@/lib/blueskyPostClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

type Action = { kind: SocialEngagementKind; did: string; key: readonly unknown[]; existingUri?: string; uri: string; cid: string; moderation: ModerationOpts };

export function useBlueskyPostEngagement(post: AppBskyFeedDefs.PostView, moderation: ModerationOpts | undefined) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const client = useQueryClient();
  const busy = useRef<string | null>(null);
  const viewerDid = useRef(session?.did);
  useEffect(() => { viewerDid.current = session?.did; }, [session?.did]);
  const key = ["blueskySocial", session?.did ?? "", "engagement", oauthSessionReloadSeq, post.uri] as const;
  const initial: SocialPostEngagement = { like: post.viewer?.like, repost: post.viewer?.repost, likeCount: post.likeCount ?? 0, repostCount: post.repostCount ?? 0 };
  const state = useQuery({ queryKey: key, queryFn: () => initial, initialData: initial, enabled: false });
  const requireSession = (action: Action) => {
    const oauth = getOAuthSession();
    if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
    if (oauth.did !== action.did || viewerDid.current !== action.did || action.moderation.userDid !== action.did) throw new Error("Your account changed. Please reload this post.");
    return oauth;
  };
  const mutation = useMutation({
    mutationFn: (action: Action) => setBlueskyPostEngagement({ ...action, session: requireSession(action) }),
    onMutate: async action => {
      requireSession(action);
      await client.cancelQueries({ queryKey: action.key, exact: true });
      requireSession(action);
      const previous = client.getQueryData<SocialPostEngagement>(action.key);
      if (!previous) throw new Error("Your account changed. Please reload this post.");
      const countKey = action.kind === "like" ? "likeCount" : "repostCount";
      client.setQueryData(action.key, { ...previous, [action.kind]: action.existingUri ? undefined : "pending", [countKey]: Math.max(0, previous[countKey] + (action.existingUri ? -1 : 1)) });
      return previous;
    },
    onSuccess: (uri, action) => {
      if (viewerDid.current !== action.did || getOAuthSession()?.did !== action.did) return;
      client.setQueryData<SocialPostEngagement>(action.key, current => current ? { ...current, [action.kind]: uri } : current);
      void client.invalidateQueries({ predicate: query => query.queryKey[0] === "blueskySocial" && query.queryKey[1] === action.did && ["timeline", "profileTimeline", "thread"].includes(String(query.queryKey[2])) });
    },
    onError: (_error, action, previous) => {
      if (previous && viewerDid.current === action.did && getOAuthSession()?.did === action.did) client.setQueryData(action.key, previous);
    },
    onSettled: (_data, _error, action) => { if (busy.current === action.did) busy.current = null; },
  });
  const toggle = (kind: SocialEngagementKind) => {
    if (!session || busy.current === session.did || moderation?.userDid !== session.did) return;
    busy.current = session.did;
    mutation.mutate({ kind, did: session.did, key, existingUri: state.data[kind], uri: post.uri, cid: post.cid, moderation });
  };
  return { engagement: state.data, toggleLike: () => toggle("like"), toggleRepost: () => toggle("repost"), isPending: mutation.isPending && mutation.variables?.did === session?.did, error: mutation.variables?.did === session?.did ? mutation.error : null };
}
