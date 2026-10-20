"use client";

import { useState } from "react";
import type { AppBskyDraftDefs } from "@atproto/api";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { useAuth } from "@/hooks/useAuth";
import { useSocialDraftList } from "@/hooks/useSocialDraftList";
import { isMissingOAuthScope, SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialComposeButton } from "./SocialComposeButton";
import { SocialDraftRow } from "./SocialDraftRow";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";

export function SocialDrafts() {
  const { session, oauthSessionReloadSeq } = useAuth();
  return <SocialDraftsViewer key={`${session?.did ?? "signed-out"}:${oauthSessionReloadSeq ?? 0}`} />;
}

function SocialDraftsViewer() {
  const { did, list, drafts, deletion, onDraftChanged } = useSocialDraftList();
  const [editor, setEditor] = useState<{ draft?: AppBskyDraftDefs.DraftView } | null>(null);
  const [deleting, setDeleting] = useState<AppBskyDraftDefs.DraftView | null>(null);
  const scopeError = (error: unknown) => isMissingOAuthScope(error) || (error instanceof Error && error.message === SCOPE_RECOVERY_MESSAGE);
  return <div className="flex min-h-0 w-full flex-1 flex-col">
    <FeedHeader title="Drafts" subtitle="Social">
      <Button variant="outline" size="sm" disabled={!did || list.isFetching} onClick={() => { void list.refetch(); }}>Refresh</Button>
      <Button size="sm" disabled={!did || deletion.isPending} onClick={() => setEditor({})}>New Post</Button>
    </FeedHeader>
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain"><section className="mx-auto flex w-full max-w-3xl flex-col gap-4 p-4" aria-label="Saved Drafts">
      {!did ? <p>Log in to view your private drafts.</p> : <>
        {list.isPending ? <p role="status">Loading drafts…</p> : null}
        {list.error ? <div role="alert"><p>{scopeError(list.error) ? SCOPE_RECOVERY_MESSAGE : "Drafts could not be loaded. Please retry."}</p>{scopeError(list.error) ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={() => { void (list.isFetchNextPageError ? list.fetchNextPage() : list.refetch()); }}>Retry</Button>}</div> : null}
        {!list.isPending && !list.error && !drafts.length ? <div className="space-y-2 py-12 text-center"><h2 className="font-semibold">No Drafts Yet</h2><p className="text-sm text-muted-foreground">Your posts are autosaved as drafts while you write.</p><Button onClick={() => setEditor({})}>New Post</Button></div> : null}
        {drafts.map(draft => <SocialDraftRow key={draft.id} draft={draft} disabled={deletion.isPending} onOpen={() => setEditor({ draft })} onDelete={() => { deletion.reset(); setDeleting(draft); }} />)}
        {list.hasNextPage ? <Button variant="outline" disabled={list.isFetching} onClick={() => { void list.fetchNextPage(); }}>{list.isFetchingNextPage ? "Loading More…" : "Load More"}</Button> : null}
      </>}
    </section></div>
    {editor ? <SocialComposeButton initialDraft={editor.draft} autoOpen hideTrigger onClose={() => setEditor(null)} onDraftChanged={onDraftChanged} /> : null}
    <Dialog open={!!deleting} onOpenChange={open => { if (!open && !deletion.isPending) setDeleting(null); }}>
      <DialogContent showCloseButton={!deletion.isPending}>
        <DialogTitle>Delete Draft?</DialogTitle>
        <DialogDescription>Delete this saved draft? This cannot be undone.</DialogDescription>
        {deletion.error ? <div role="alert"><p>{scopeError(deletion.error) ? SCOPE_RECOVERY_MESSAGE : "The draft could not be deleted. Please retry."}</p>{scopeError(deletion.error) ? <SocialPermissionRecovery /> : null}</div> : null}
        <div className="flex gap-2"><Button variant="destructive" disabled={deletion.isPending} onClick={() => { if (deleting) deletion.mutate(deleting.id, { onSuccess: () => setDeleting(null) }); }}>{deletion.isPending ? "Deleting…" : deletion.error ? "Retry Delete" : "Delete Draft"}</Button><DialogClose render={<Button variant="outline" disabled={deletion.isPending} />}>Cancel</DialogClose></div>
      </DialogContent>
    </Dialog>
  </div>;
}
