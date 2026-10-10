"use client";

import { useInfiniteQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { getBlueskyConversations, getBlueskyMessages, performBlueskyChatAction, type ChatAction } from "@/lib/blueskyChatClient";
import { getAtprotoNetwork } from "@/lib/atprotoNetwork";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

function nextCursor(page: { cursor?: string }, params: unknown[]) {
  return page.cursor && !params.includes(page.cursor) ? page.cursor : undefined;
}

export function useBlueskyMessages(convoId?: string) {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const client = useQueryClient();
  const prefix = ["blueskySocial", session?.did ?? "", "messages", oauthSessionReloadSeq] as const;
  const available = !!getAtprotoNetwork().chatServiceDid;
  function requireSession(did = session?.did) {
    const oauth = getOAuthSession();
    if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
    if (!did || oauth.did !== did) throw new Error("Your account changed. Please reload Messages.");
    return oauth;
  }
  const conversations = useInfiniteQuery({
    queryKey: [...prefix, "conversations"], enabled: available && !!session,
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam, signal }) => getBlueskyConversations({ session: requireSession(), viewerDid: session!.did, cursor: pageParam, signal }),
    getNextPageParam: (page, _pages, _param, params) => nextCursor(page, params),
    retry: false, staleTime: 10_000, refetchInterval: 30_000,
  });
  const messages = useInfiniteQuery({
    queryKey: [...prefix, "conversation", convoId], enabled: available && !!session && !!convoId,
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam, signal }) => getBlueskyMessages({ session: requireSession(), viewerDid: session!.did, convoId: convoId!, cursor: pageParam, signal }),
    getNextPageParam: (page, _pages, _param, params) => nextCursor(page, params),
    retry: false, staleTime: 3_000, refetchInterval: 5_000,
  });
  const action = useMutation({
    mutationFn: ({ did, action }: { did: string; action: ChatAction }) => performBlueskyChatAction(requireSession(did), did, action),
    onSuccess: (_result, variables) => {
      if (getOAuthSession()?.did !== variables.did) return;
      void client.invalidateQueries({ queryKey: ["blueskySocial", variables.did, "messages"] });
    },
  });
  return { available, conversations, messages, action, perform: (value: ChatAction) => {
    if (!session) return Promise.reject(new Error(SCOPE_RECOVERY_MESSAGE));
    return action.mutateAsync({ did: session.did, action: value });
  } };
}
