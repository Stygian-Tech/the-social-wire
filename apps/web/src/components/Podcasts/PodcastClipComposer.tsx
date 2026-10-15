"use client";
import { useState } from "react";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { postTextLength } from "@/lib/blueskyComposeClient";
import { SocialPeopleTextField } from "@/components/Social/SocialPeopleTextField";
import { PodcastClipPreview } from "./PodcastClipPreview";
import { useViewerProfile } from "@/hooks/useViewerProfile";
import { Avatar } from "@/components/shared/Avatar";
import { SocialPermissionRecovery } from "@/components/Social/SocialPermissionRecovery";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

export function PodcastClipComposer({ open, onOpenChange, title, url, accountDid, pending, progress, error, onPublish, onPlay, onCancel }: {
  open: boolean; onOpenChange: (open: boolean) => void; title: string; url: string; accountDid: string;
  pending: boolean; progress: string | null; error: string | null; onPublish: (text: string) => void; onPlay: () => void; onCancel: () => void;
}) {
  const [text, setText] = useState("");
  const [review, setReview] = useState(false);
  const profileQuery = useViewerProfile();
  const profile = profileQuery.data?.did === accountDid ? profileQuery.data : undefined;
  const name = profile?.displayName || (profile?.handle && !profile.handle.startsWith("did:") ? profile.handle : "Personal Account");
  const length = postTextLength(text, { markdown: false });
  const valid = length.graphemes <= 300 && length.bytes <= 3000;
  return <Dialog open={open} onOpenChange={next => { if (!pending) onOpenChange(next); }}>
    <DialogContent className="min-w-0 grid-cols-[minmax(0,1fr)] max-h-[calc(100dvh-2rem)] overflow-y-auto sm:max-w-xl">
      <DialogHeader><DialogTitle>{review ? "Review Bluesky Post" : "Post Clip to Bluesky"}</DialogTitle>
        <DialogDescription>Review Your Video and Commentary Before Publishing</DialogDescription></DialogHeader>
      <div className="flex min-w-0 items-center gap-2" title={accountDid}><Avatar src={profile?.avatar} alt="" size={32} />
        <div className="min-w-0 text-sm"><p className="truncate font-medium">Posting As {name}</p>{profile?.handle && !profile.handle.startsWith("did:") ? <p className="truncate text-xs text-muted-foreground">@{profile.handle}</p> : null}</div></div>
      <PodcastClipPreview url={url} title={title} onPlay={onPlay} />
      {review ? <p className="whitespace-pre-wrap break-words rounded-xl border p-3">{text || "Video Post Without Commentary"}</p> :
        <label className="space-y-2 text-sm">Commentary<SocialPeopleTextField aria-label="Commentary" value={text} disabled={pending}
          onValueChange={setText} placeholder="Add a Comment…" rows={3} className="w-full rounded-xl border bg-background p-3" />
          <span className={`block text-xs ${valid ? "text-muted-foreground" : "text-destructive"}`}>{length.graphemes}/300 Characters</span></label>}
      {error ? <p role="alert" className="min-w-0 [overflow-wrap:anywhere] text-sm text-destructive">{error}</p> : null}
      {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
      {progress ? <p role="status" className="text-sm text-muted-foreground">{progress}</p> : null}
      <div className="flex flex-wrap justify-end gap-2">
        {pending ? <button type="button" className="rounded-lg border px-3 py-2 text-sm" onClick={onCancel}>Cancel Upload</button> : <DialogClose className="rounded-lg border px-3 py-2 text-sm">Cancel</DialogClose>}
        {review ? <><button disabled={pending} className="rounded-lg border px-3 py-2 text-sm" onClick={() => setReview(false)}>Edit Commentary</button>
          <button disabled={pending || !valid} className="rounded-lg bg-primary px-3 py-2 text-sm text-primary-foreground" onClick={() => onPublish(text)}>{pending ? "Publishing…" : "Publish to Bluesky"}</button></> :
          <button disabled={!valid} className="rounded-lg bg-primary px-3 py-2 text-sm text-primary-foreground" onClick={() => setReview(true)}>Review Post</button>}
      </div>
    </DialogContent>
  </Dialog>;
}
