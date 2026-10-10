"use client";

import { useRef } from "react";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import { useAuth } from "./useAuth";
import { getBlueskyBookmarks, setBlueskyBookmark } from "@/lib/blueskyBookmarksClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function useBlueskyBookmarks(moderation?: ModerationOpts) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  return useInfiniteQuery({
    queryKey: ["blueskySocial", session?.did ?? "", "bookmarks", oauthSessionReloadSeq, moderation?.prefs.labelers.map(labeler => labeler.did)],
    enabled: !!session && moderation?.userDid === session.did,
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam, signal }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      if (oauth.did !== session?.did || !moderation) throw new Error("Your account changed. Please reload Bookmarks.");
      return getBlueskyBookmarks({ session: oauth, moderation, cursor: pageParam, signal });
    },
    getNextPageParam: (page, _pages, _last, params) => page.cursor && !params.includes(page.cursor) ? page.cursor : undefined,
    retry: false, staleTime: 30_000,
  });
}

export function useBlueskyBookmark(post: AppBskyFeedDefs.PostView, moderation: ModerationOpts) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const client = useQueryClient();
  const busy = useRef(false);
  const key = ["blueskySocial", session?.did ?? "", "bookmarkState", oauthSessionReloadSeq, post.uri] as const;
  const state = useQuery({ queryKey: key, queryFn: () => !!post.viewer?.bookmarked, initialData: !!post.viewer?.bookmarked, enabled: false });
  const mutation = useMutation({
    mutationFn: async ({ did, saved }: { did: string; saved: boolean }) => {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      if (oauth.did !== did || moderation.userDid !== did) throw new Error("Your account changed. Please reload this post.");
      await setBlueskyBookmark({ session: oauth, moderation, uri: post.uri, cid: post.cid, saved });
    },
    onSuccess: (_data, action) => {
      if (getOAuthSession()?.did !== action.did) return;
      client.setQueryData(["blueskySocial", action.did, "bookmarkState", oauthSessionReloadSeq, post.uri], action.saved);
      void client.invalidateQueries({ predicate: query => query.queryKey[0] === "blueskySocial" && query.queryKey[1] === action.did && ["bookmarks", "timeline", "profileTimeline", "thread"].includes(String(query.queryKey[2])) });
    },
    onSettled: () => { busy.current = false; },
  });
  return { saved: state.data, isPending: mutation.isPending, error: mutation.error, toggle: () => {
    if (busy.current || !session || moderation.userDid !== session.did) return;
    busy.current = true; mutation.mutate({ did: session.did, saved: !state.data });
  } };
}
