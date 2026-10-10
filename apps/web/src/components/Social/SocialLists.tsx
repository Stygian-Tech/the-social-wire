"use client";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { useAuth } from "@/hooks/useAuth";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { useState } from "react";
import Link from "next/link";
import { moderateProfile, moderateUserList } from "@atproto/api";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { useSocialLists } from "@/hooks/useSocialLists";
import { addSocialListMember, deleteSocialList, removeSocialListMember, saveSocialList } from "@/lib/socialListsClient";
import { socialErrorMessage, socialFeedHref } from "@/lib/blueskySocialClient";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";

export function SocialLists() {
  const { session } = useAuth();
  return <SocialListsViewer key={session?.did ?? "signed-out"} />;
}

function SocialListsViewer() {
  const [selected, setSelected] = useState<string | null>(null);
  const [editor, setEditor] = useState<{ uri?: string; name: string; description: string } | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [removing, setRemoving] = useState<string | null>(null);
  const [openUri, setOpenUri] = useState("");
  const [actor, setActor] = useState("");
  const { did, lists, detail, mutation } = useSocialLists(selected);
  const catalog = useBlueskySocialCatalog();
  const list = detail.data?.pages[0]?.list;
  const moderation = !catalog.isError && catalog.data?.moderation.userDid === did ? catalog.data.moderation : undefined;
  const listSafe = list && moderation && !["contentList", "contentView", "profileList"].some(context => { const ui = moderateUserList(list, moderation).ui(context as "contentList"); return ui.filter || ui.blur || ui.noOverride; });
  const own = list?.creator.did === did;
  const members = Array.from(new Map(detail.data?.pages.flatMap(page => page.items).map(item => [item.subject.did, item]) ?? []).values());
  const allLists = Array.from(new Map(lists.data?.pages.flatMap(page => page.lists).map(item => [item.uri, item]) ?? []).values());
  return <div className="flex min-h-0 w-full flex-1 flex-col"><FeedHeader title="Lists" subtitle="Social" /><div className="min-h-0 flex-1 overflow-y-auto overscroll-contain"><section className="mx-auto flex w-full max-w-3xl flex-col gap-4 p-4">
    <div className="flex justify-end gap-3"><Button disabled={!did} onClick={() => { mutation.reset(); setEditor({ name: "", description: "" }); }}>Create List</Button></div>
    <form className="flex gap-2" onSubmit={event => { event.preventDefault(); if (/^at:\/\/did:[^/]+\/app\.bsky\.graph\.list\/[^/?#]+$/.test(openUri.trim())) { setSelected(openUri.trim()); mutation.reset(); } }}><Input aria-label="List AT URI" placeholder="at://…/app.bsky.graph.list/…" value={openUri} onChange={event => setOpenUri(event.target.value)} /><Button type="submit" disabled={!/^at:\/\/did:[^/]+\/app\.bsky\.graph\.list\/[^/?#]+$/.test(openUri.trim())}>Open List</Button></form>
    {lists.error || detail.error || mutation.error || catalog.error ? <div role="alert"><p>{socialErrorMessage(lists.error ?? detail.error ?? mutation.error ?? catalog.error)}</p>{socialErrorMessage(lists.error ?? detail.error ?? mutation.error ?? catalog.error) === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" onClick={() => { void lists.refetch(); if (selected) void detail.refetch(); void catalog.refetch(); mutation.reset(); }}>Retry</Button>}</div> : null}
    {lists.isPending || catalog.isPending ? <p role="status">Loading lists…</p> : null}
    {moderation ? <nav aria-label="Your Lists" className="flex flex-wrap gap-2">{allLists.map(item => {
      const decision = moderateUserList(item, moderation);
      if (["contentList", "contentView", "profileList"].some(context => { const ui = decision.ui(context as "contentList"); return ui.filter || ui.blur || ui.noOverride; })) return null;
      return <Button key={item.uri} variant={selected === item.uri ? "default" : "outline"} onClick={() => { mutation.reset(); setActor(""); setSelected(item.uri); }}>{item.name}</Button>;
    })}</nav> : null}
    {!lists.isPending && !lists.error && !allLists.length ? <p>You haven’t created any lists yet.</p> : null}
    {lists.hasNextPage ? <Button variant="outline" disabled={lists.isFetchingNextPage} onClick={() => { void lists.fetchNextPage(); }}>Load More Lists</Button> : null}
    {selected && detail.isPending ? <p role="status">Loading list…</p> : null}
    {listSafe && list ? <article className="flex flex-col gap-4 rounded-xl border bg-card p-4">
      <div><h2 className="font-semibold">{list.name}</h2><p className="whitespace-pre-wrap break-words text-sm">{list.description}</p></div>
      <div className="flex flex-wrap gap-2">
        {list.purpose === "app.bsky.graph.defs#curatelist" ? <Link className="rounded-md border px-3 py-2 text-sm hover:bg-muted" href={socialFeedHref({ kind: "list", uri: list.uri, name: list.name, pinned: false })}>Open List Feed</Link> : <p className="text-sm text-muted-foreground">This moderation list does not provide a timeline.</p>}
        {own ? <><Button variant="outline" onClick={() => { mutation.reset(); setEditor({ uri: list.uri, name: list.name, description: list.description ?? "" }); }}>Edit List</Button><Button variant="destructive" onClick={() => setDeleting(true)}>Delete List</Button></> : null}
      </div>
      <h3 className="font-medium">Members</h3>
      {own ? <form className="flex gap-2" onSubmit={event => { event.preventDefault(); mutation.mutate(session => addSocialListMember(session, list.uri, actor), { onSuccess: () => setActor("") }); }}><Input aria-label="Member Handle Or DID" value={actor} onChange={event => setActor(event.target.value)} placeholder="Handle or DID" /><Button type="submit" disabled={mutation.isPending || !actor.trim()}>Add Member</Button></form> : null}
      {members.map(item => {
        const decision = moderateProfile(item.subject, moderation!);
        if (decision.ui("profileList").filter || decision.ui("profileList").blur || decision.ui("profileList").noOverride || decision.ui("displayName").blur || decision.ui("displayName").noOverride) return null;
        return <div key={item.uri} className="flex items-center justify-between gap-3"><span className="min-w-0 break-all">@{item.subject.handle}</span>{own ? <Button variant="outline" disabled={mutation.isPending} onClick={() => { mutation.reset(); setRemoving(item.uri); }}>Remove Member</Button> : null}</div>;
      })}
      {!members.length ? <p className="text-sm text-muted-foreground">No members yet.</p> : null}
      {detail.hasNextPage ? <Button variant="outline" disabled={detail.isFetchingNextPage} onClick={() => { void detail.fetchNextPage(); }}>Load More Members</Button> : null}
    </article> : selected && list && moderation ? <p>This list is withheld by your moderation settings.</p> : null}
    <Dialog open={!!editor} onOpenChange={open => { if (!open && !mutation.isPending) setEditor(null); }}><DialogContent><DialogTitle>{editor?.uri ? "Edit List" : "Create List"}</DialogTitle><DialogDescription>Create a curated list of accounts.</DialogDescription><form className="flex flex-col gap-3" onSubmit={event => { event.preventDefault(); if (editor) mutation.mutate(session => saveSocialList(session, editor.name, editor.description, editor.uri), { onSuccess: uri => { setSelected(uri as string); setEditor(null); } }); }}><label className="flex flex-col gap-1">Name<Input value={editor?.name ?? ""} maxLength={64} required onChange={event => setEditor(value => value && { ...value, name: event.target.value })} /></label><label className="flex flex-col gap-1">Description<Input value={editor?.description ?? ""} maxLength={300} onChange={event => setEditor(value => value && { ...value, description: event.target.value })} /></label>{mutation.error ? <div role="alert"><p>{socialErrorMessage(mutation.error)}</p>{socialErrorMessage(mutation.error) === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}</div> : null}<div className="flex gap-2"><Button type="submit" disabled={mutation.isPending}>Save List</Button><DialogClose render={<Button variant="outline" disabled={mutation.isPending} />}>Cancel</DialogClose></div></form></DialogContent></Dialog>
    <Dialog open={!!removing} onOpenChange={open => { if (!open) setRemoving(null); }}><DialogContent><DialogTitle>Remove Member?</DialogTitle><DialogDescription>This account will be removed from the list.</DialogDescription>{mutation.error ? <div role="alert"><p>{socialErrorMessage(mutation.error)}</p>{socialErrorMessage(mutation.error) === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}</div> : null}<div className="flex gap-2"><Button variant="destructive" disabled={mutation.isPending} onClick={() => { if (removing) mutation.mutate(session => removeSocialListMember(session, removing), { onSuccess: () => setRemoving(null) }); }}>Remove Member</Button><DialogClose render={<Button variant="outline" disabled={mutation.isPending} />}>Cancel</DialogClose></div></DialogContent></Dialog>
    <Dialog open={deleting} onOpenChange={setDeleting}><DialogContent><DialogTitle>Delete List?</DialogTitle><DialogDescription>This deletes the list and its membership records. This cannot be undone.</DialogDescription>{mutation.error ? <div role="alert"><p>{socialErrorMessage(mutation.error)}</p>{socialErrorMessage(mutation.error) === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}</div> : null}<div className="flex gap-2"><Button variant="destructive" disabled={mutation.isPending} onClick={() => { if (list) mutation.mutate(session => deleteSocialList(session, list.uri), { onSuccess: () => { setDeleting(false); setSelected(null); } }); }}>Delete List</Button><DialogClose render={<Button variant="outline" disabled={mutation.isPending} />}>Cancel</DialogClose></div></DialogContent></Dialog>
  </section></div></div>;
}
