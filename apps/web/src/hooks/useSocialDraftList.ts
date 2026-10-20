"use client";

import { useLayoutEffect, useRef } from "react";
import type { AppBskyDraftDefs } from "@atproto/api";
import { useInfiniteQuery, useMutation, useQueryClient, type InfiniteData } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { deleteSocialDraft, listSocialDrafts } from "@/lib/blueskyDraftClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

type DraftPage = { drafts: AppBskyDraftDefs.DraftView[]; cursor?: string };

export function useSocialDraftList() {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const did = session?.did ?? "";
  const sequence = oauthSessionReloadSeq ?? 0;
  const current = useRef({ did, sequence, getOAuthSession });
  useLayoutEffect(() => { current.current = { did, sequence, getOAuthSession }; }, [did, sequence, getOAuthSession]);
  const mounted = useRef(true);
  useLayoutEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const cache = useQueryClient();
  // Confirmed deletes remain hidden while the private service indexes them.
  const deleted = useRef(new Set<string>());
  const queryKey = ["socialDrafts", did, sequence] as const;

  function requireActor() {
    const oauth = getOAuthSession();
    if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
    const assertCurrentActor = () => {
      if (!mounted.current || !did || oauth.did !== did || current.current.did !== did || current.current.sequence !== sequence || current.current.getOAuthSession() !== oauth) {
        throw new Error("Your account changed. Please reload your drafts.");
      }
    };
    assertCurrentActor();
    return { session: oauth, viewerDid: did, assertCurrentActor };
  }

  const list = useInfiniteQuery({
    queryKey,
    enabled: !!did,
    initialPageParam: undefined as string | undefined,
    queryFn: async ({ pageParam, signal }) => {
      const actor = requireActor();
      try {
        const page = await listSocialDrafts({ ...actor, cursor: pageParam, signal });
        return { ...page, drafts: page.drafts.filter(draft => !deleted.current.has(draft.id)) };
      }
      finally { actor.assertCurrentActor(); }
    },
    getNextPageParam: (page, _pages, _last, pageParams) => page.cursor && !pageParams.includes(page.cursor) ? page.cursor : undefined,
    retry: false,
    gcTime: 0,
  });
  const deletion = useMutation({
    mutationKey: ["socialDrafts", did, sequence, "delete"],
    retry: false,
    gcTime: 0,
    mutationFn: async (id: string) => {
      const actor = requireActor();
      try { await deleteSocialDraft({ ...actor, id }); }
      finally { actor.assertCurrentActor(); }
      deleted.current.add(id);
      // Remove only after a confirmed delete; leave the row intact on any failure.
      cache.setQueryData<InfiniteData<DraftPage>>(queryKey, data => data && ({ ...data, pages: data.pages.map(page => ({ ...page, drafts: page.drafts.filter(draft => draft.id !== id) })) }));
      void cache.invalidateQueries({ queryKey: ["socialDrafts", did] });
    },
  });
  const byId = new Map<string, AppBskyDraftDefs.DraftView>();
  for (const page of list.data?.pages ?? []) {
    for (const draft of page.drafts) {
      if (deleted.current.has(draft.id)) continue;
      const previous = byId.get(draft.id);
      if (!previous || Date.parse(draft.updatedAt) > Date.parse(previous.updatedAt)) byId.set(draft.id, draft);
    }
  }
  const drafts = Array.from(byId.values()).sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt));
  return { did, sequence, list, drafts, deletion, onDraftChanged: () => { void cache.invalidateQueries({ queryKey: ["socialDrafts", did] }); } };
}
