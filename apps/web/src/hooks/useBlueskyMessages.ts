"use client";

import { useLayoutEffect, useRef } from "react";
import { useInfiniteQuery, useMutation, useQueryClient, type InfiniteData } from "@tanstack/react-query";
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
  const currentViewer = useRef(session?.did);
  const mounted = useRef(true);
  useLayoutEffect(() => { currentViewer.current = session?.did; mounted.current = true; return () => { mounted.current = false; }; }, [session?.did]);
  const prefix = ["blueskySocial", session?.did ?? "", "messages", oauthSessionReloadSeq] as const;
  const available = !!getAtprotoNetwork().chatServiceDid;
  function requireSession(did = session?.did) {
    const oauth = getOAuthSession();
    if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
    if (!mounted.current || !did || oauth.did !== did || currentViewer.current !== did) throw new Error("Your account changed. Please reload Messages.");
    return oauth;
  }
  const conversations = useInfiniteQuery({
    queryKey: [...prefix, "conversations"], enabled: available && !!session,
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam, signal }) => getBlueskyConversations({ session: requireSession(), viewerDid: session!.did, cursor: pageParam, status: "accepted", signal }),
    getNextPageParam: (page, _pages, _param, params) => nextCursor(page, params),
    retry: false, staleTime: 10_000, refetchInterval: 30_000,
  });
  const requests = useInfiniteQuery({
    queryKey: [...prefix, "requests"], enabled: available && !!session,
    initialPageParam: undefined as string | undefined,
    queryFn: ({ pageParam, signal }) => getBlueskyConversations({ session: requireSession(), viewerDid: session!.did, cursor: pageParam, status: "request", signal }),
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
    mutationFn: ({ did, action }: { did: string; action: ChatAction }) => performBlueskyChatAction(requireSession(did), did, action, () => { requireSession(did); }),
    onSuccess: async (result, variables) => {
      if (!mounted.current || currentViewer.current !== variables.did || getOAuthSession()?.did !== variables.did) return;
      const value = variables.action;
      const key = ["blueskySocial", variables.did, "messages", oauthSessionReloadSeq];
      await client.cancelQueries({ queryKey: key });
      if (!mounted.current || currentViewer.current !== variables.did || getOAuthSession()?.did !== variables.did) return;
      type Conversations = InfiniteData<Awaited<ReturnType<typeof getBlueskyConversations>>, string | undefined>;
      if ("convoId" in value) {
        const requested = client.getQueryData<Conversations>([...key, "requests"])?.pages.flatMap(page => page.convos).find(convo => convo.id === value.convoId);
        const replacement = "convo" in result ? result.convo : undefined;
        for (const section of ["conversations", "requests"]) client.setQueryData<Conversations>([...key, section], cached => {
          if (!cached) return cached;
          const pages = cached.pages.map(page => ({ ...page, convos: page.convos.flatMap(convo => {
            if (convo.id !== value.convoId) return [convo];
            if (value.kind === "leave" || (value.kind === "accept" && section === "requests")) return [];
            if (replacement) return [replacement];
            return [convo];
          }) }));
          if (value.kind === "accept" && section === "conversations" && requested && !pages.some(page => page.convos.some(convo => convo.id === requested.id))) {
            pages[0] = { ...pages[0], convos: [{ ...requested, status: "accepted" }, ...pages[0].convos] };
          }
          return { ...cached, pages };
        });
        if (value.kind === "leave") client.removeQueries({ queryKey: [...key, "conversation", value.convoId] });
      }
      if (value.kind === "block" || value.kind === "unblock") void client.invalidateQueries({ queryKey: ["blueskySocial", variables.did, "catalog"] });
      void client.invalidateQueries({ queryKey: ["blueskySocial", variables.did, "messages"] });
    },
  });
  return { available, conversations, requests, messages, action, perform: (value: ChatAction) => {
    if (!session) return Promise.reject(new Error(SCOPE_RECOVERY_MESSAGE));
    return action.mutateAsync({ did: session.did, action: value });
  } };
}
