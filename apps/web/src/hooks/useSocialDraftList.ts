"use client";

import { useLayoutEffect, useRef, useState } from "react";
import type { AppBskyDraftDefs } from "@atproto/api";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient, type InfiniteData } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { deleteSocialDraft, listSocialDrafts } from "@/lib/blueskyDraftClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { deleteDraftAttachmentManifest, getDraftAttachmentManifest } from "@/lib/socialDraftAttachmentClient";
import { pendingDraftDeletions, saveDraftDeletion, type PendingDraftDeletion } from "@/lib/socialDraftDeletionStorage";

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
  const [deletedIds, setDeletedIds] = useState<ReadonlySet<string>>(new Set());
  const queryKey = ["socialDrafts", did, sequence] as const;
  const recoveryKey = ["socialDraftDeletionRecovery", did, sequence] as const;
  const recovery = useQuery({ queryKey: recoveryKey, enabled: !!did, queryFn: () => pendingDraftDeletions(did), retry: false, gcTime: 0 });

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
      const pending = await cache.ensureQueryData({ queryKey: recoveryKey, queryFn: () => pendingDraftDeletions(did) });
      actor.assertCurrentActor();
      const draft = pending.find(item => item.draft.id === id)?.draft
        ?? list.data?.pages.flatMap(page => page.drafts).find(draft => draft.id === id);
      if (!draft) throw new Error("Reload Your Drafts Before Deleting.");
      // Persist before the first destructive write. A failed attachment cleanup
      // remains visible even after the native service stops returning the draft.
      await saveDraftDeletion(did, draft);
      actor.assertCurrentActor();
      cache.setQueryData<PendingDraftDeletion[]>(recoveryKey, data => [...(data ?? []).filter(item => item.draft.id !== id), { ownerDid: did, draft }]);
      try {
        await deleteSocialDraft({ ...actor, id });
        const manifest = await getDraftAttachmentManifest(actor, id);
        if (!manifest.deleted && manifest.revision > 0) await deleteDraftAttachmentManifest(actor, id, manifest.revision);
        await saveDraftDeletion(did, draft, true);
      }
      finally { actor.assertCurrentActor(); }
      cache.setQueryData<PendingDraftDeletion[]>(recoveryKey, data => data?.filter(item => item.draft.id !== id));
      deleted.current.add(id);
      setDeletedIds(new Set(deleted.current));
      // Remove only after a confirmed delete; leave the row intact on any failure.
      cache.setQueryData<InfiniteData<DraftPage>>(queryKey, data => data && ({ ...data, pages: data.pages.map(page => ({ ...page, drafts: page.drafts.filter(draft => draft.id !== id) })) }));
      void cache.invalidateQueries({ queryKey: ["socialDrafts", did] });
    },
  });
  const byId = new Map<string, AppBskyDraftDefs.DraftView>();
  for (const page of list.data?.pages ?? []) {
    for (const draft of page.drafts) {
      if (deletedIds.has(draft.id)) continue;
      const previous = byId.get(draft.id);
      if (!previous || Date.parse(draft.updatedAt) > Date.parse(previous.updatedAt)) byId.set(draft.id, draft);
    }
  }
  const pendingDeletionIds = new Set(recovery.data?.map(item => item.draft.id));
  for (const item of recovery.data ?? []) byId.set(item.draft.id, item.draft);
  const drafts = Array.from(byId.values()).sort((a, b) => Date.parse(b.updatedAt) - Date.parse(a.updatedAt));
  return { did, sequence, list, drafts, deletion, recovery, pendingDeletionIds, onDraftChanged: () => { void cache.invalidateQueries({ queryKey: ["socialDrafts", did] }); } };
}
