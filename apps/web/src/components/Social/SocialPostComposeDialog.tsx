"use client";

import { useId, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { AppBskyFeedPost, moderateProfile, type ModerationOpts, type AppBskyFeedDefs } from "@atproto/api";
import { useComposeLinkPreview } from "@/hooks/useComposeLinkPreview";
import { SocialComposeLinkCard } from "./SocialComposeLinkCard";
import { useComposerDraft } from "@/hooks/useComposerDraft";
import { newThreadPublication, validThreadText, type ThreadPublication } from "@/lib/blueskyThreadClient";
import { composeLinkUrl } from "@/lib/blueskyExternalEmbed";
import { missingMediaAlt, type ComposerMedia } from "@/lib/composerMedia";
import { SocialMediaControls } from "./SocialMediaControls";
import { useAuth } from "@/hooks/useAuth";
import { getStoredOAuthDid } from "@/lib/auth";
import { createBlueskyPost, postTextLength } from "@/lib/blueskyComposeClient";
import { refreshSocialPostQueries } from "@/lib/socialPostRefresh";
import { composerErrorMessage } from "@/lib/composerErrorMessage";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogTitle } from "@/components/ui/dialog";
import { SocialComposePreview } from "./SocialComposePreview";
import { SocialPeopleTextField } from "./SocialPeopleTextField";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { SocialPostCard } from "./SocialPostCard";
import { handlePostComposerShortcut } from "@/lib/postComposerShortcut";

type ComposeProps = {
  post: AppBskyFeedDefs.PostView;
  moderation: ModerationOpts;
  mode: "reply" | "quote";
  trigger: (openComposer: () => void, disabled: boolean) => ReactNode;
};

export function SocialPostComposeDialog(props: ComposeProps) {
  const { session } = useAuth();
  return <SocialAccountPostComposeDialog key={`${session?.did ?? ""}:${props.post.uri}:${props.mode}`} {...props} />;
}

function SocialAccountPostComposeDialog({ post, moderation, mode, trigger }: ComposeProps) {
  const { session, getOAuthSession } = useAuth();
  const cache = useQueryClient();
  const fieldId = useId();
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const [media, setMedia] = useState<ComposerMedia>();
  const [removedLinkUrl, setRemovedLinkUrl] = useState<string>();
  const [locked, setLocked] = useState(false);
  const [discardRequested, setDiscardRequested] = useState(false);
  const [altWarning, setAltWarning] = useState(false);
  const [mediaProgress, setMediaProgress] = useState<string>();
  const publication = useRef<ThreadPublication | undefined>(undefined);
  const intake = useRef<((files: File[]) => void) | undefined>(undefined);
  const segments = useMemo(() => [{ id: "first", text, media, removedLinkUrl, ...(mode === "quote" ? { quoteTo: post } : { replyTo: post }) }], [text, media, removedLinkUrl, mode, post]);
  const draft = useComposerDraft(session?.did ?? "", `${mode}:${post.uri}`, segments, publication, restored => { setText(restored[0].text); setMedia(restored[0].media); setRemovedLinkUrl(restored[0].removedLinkUrl); setLocked(!!publication.current?.segments.some(item => item.attempted)); }, open);
  const link = useComposeLinkPreview(text, getOAuthSession(), open && !media, removedLinkUrl);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [published, setPublished] = useState(false);
  const busy = useRef(false);
  const stopRefresh = useRef<(() => void) | undefined>(undefined);
  const currentDid = useRef(session?.did);
  useLayoutEffect(() => {
    currentDid.current = session?.did;
    return () => { currentDid.current = undefined; stopRefresh.current?.(); };
  }, [session?.did]);
  const { graphemes, bytes } = postTextLength(text);
  const valid = validThreadText(text, media);
  const identity = moderateProfile(post.author, moderation).ui("displayName");
  const recipient = identity.filter || identity.blur || identity.noOverride ? "Account" : `@${post.author.handle}`;
  const quote = mode === "quote";
  const title = quote ? "Quote Post" : "Reply";
  const disabled = !session || moderation.userDid !== session.did || (quote ? post.viewer?.embeddingDisabled : post.viewer?.replyDisabled) || !AppBskyFeedPost.validateRecord(post.record).success;

  function changeOpen(value: boolean) {
    if (busy.current) return;
    if (value) { link.reset(); setError(undefined); setPublished(false); }
    setOpen(value);
  }

  async function publish(allowMissingAlt = false) {
    if (busy.current || disabled || !valid || !session || !draft.loaded) return;
    if (!allowMissingAlt && !publication.current?.segments.some(item => item.attempted) && missingMediaAlt(media)) { setAltWarning(true); return; }
    setAltWarning(false);
    const did = session.did;
    busy.current = true;
    setPending(true);
    setError(undefined);
    try {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      const assertCurrentAccount = () => {
        if (currentDid.current !== did || getStoredOAuthDid() !== did || getOAuthSession()?.did !== did || oauth.did !== did) throw new Error("Your account changed. Please reopen the composer.");
      };
      assertCurrentAccount();
      const linkPreview = media ? undefined : link.needsResolution ? await link.resolve() : link.preview;
      assertCurrentAccount();
      publication.current ??= newThreadPublication(did, [{ ...segments[0], linkPreview }]);
      setLocked(true);
      await createBlueskyPost({ session: oauth, text, media, linkPreview, publication: publication.current, checkpoint: draft.checkpoint, onMediaProgress: setMediaProgress, ...(quote ? { quoteTo: post } : { replyTo: post }), assertCurrentAccount });
      if (currentDid.current !== did) return;
      await draft.clear();
      setOpen(false);
      publication.current = undefined; setLocked(false); setMedia(undefined); setRemovedLinkUrl(undefined);
      setText("");
      setPublished(true);
      stopRefresh.current?.();
      stopRefresh.current = refreshSocialPostQueries(cache, did, () => currentDid.current === did && getStoredOAuthDid() === did && getOAuthSession()?.did === did);
    } catch (failure) {
      if (!publication.current?.segments.some(item => item.attempted)) { publication.current = undefined; setLocked(false); }
      if (currentDid.current === did) setError(composerErrorMessage(failure));
    } finally {
      busy.current = false; setMediaProgress(undefined);
      if (currentDid.current === did) setPending(false);
    }
  }

  return <>
    <Dialog open={open} onOpenChange={changeOpen}>
      {trigger(() => {
        if (disabled || pending) return;
        link.reset(); setError(undefined); setPublished(false); setOpen(true);
      }, !!disabled)}
      <DialogContent className="max-h-[calc(100dvh-2rem)] overflow-y-auto sm:max-w-lg" showCloseButton={!pending}>
        <DialogTitle>{title}</DialogTitle>
        <DialogDescription>{quote ? "Quoting" : "Replying To"} {recipient}</DialogDescription>
        <form className="flex min-w-0 flex-col gap-3" onDragOver={event => { if (!pending && !locked && event.dataTransfer.types.includes("Files")) event.preventDefault(); }} onDrop={event => { if (!pending && !locked && event.dataTransfer.files.length) { event.preventDefault(); intake.current?.(Array.from(event.dataTransfer.files)); } }} onPaste={event => { const files = Array.from(event.clipboardData.files); if (!pending && !locked && files.length) { event.preventDefault(); intake.current?.(files); } }} onKeyDown={handlePostComposerShortcut} onSubmit={event => { event.preventDefault(); void publish(); }}>
          {quote ? <div className="max-h-48 overflow-y-auto rounded-xl border p-3"><SocialPostCard item={{ post }} moderation={moderation} embedded /></div> : null}
          <label htmlFor={fieldId} className="sr-only">{quote ? "Quote Text" : "Reply Text"}</label>
          <SocialPeopleTextField id={fieldId} autoFocus value={text} disabled={pending || locked || !draft.loaded} onValueChange={setText} rows={5} placeholder={quote ? "Add a Comment…" : "Write a Reply…"} className="w-full resize-y rounded-xl border bg-background p-3 text-base leading-relaxed" />
          <SocialComposePreview text={text} />
          <SocialMediaControls media={media} update={change => setMedia(previous => change(previous))} session={getOAuthSession()} disabled={pending || locked || !draft.loaded} hasLink={!!link.preview || link.loading} removeLink={() => { link.remove(); setRemovedLinkUrl(composeLinkUrl(text)); }} registerIntake={intake} />
          <SocialComposeLinkCard {...link} remove={() => { link.remove(); setRemovedLinkUrl(composeLinkUrl(text)); }} disabled={pending} />
          <p aria-live="polite" className={`text-right text-sm ${graphemes > 300 ? "text-destructive" : "text-muted-foreground"}`}>{graphemes}/300</p>
          {bytes > 3000 ? <p className="text-sm text-destructive">{quote ? "Quote Text" : "Reply Text"} Exceeds the Size Limit</p> : null}
          {draft.storageError ? <div role="alert">{draft.storageError}<Button type="button" variant="outline" onClick={() => void draft.checkpoint().catch(() => {})}>Retry Saving Draft</Button></div> : null}
          {mediaProgress ? <p role="status">{mediaProgress}</p> : null}
          {locked ? <p role="status">Retry Continues The Same Post Without Duplicating It.</p> : null}
          {locked && !pending ? discardRequested ? <div className="rounded-xl border p-3 text-sm"><p>Discard This Draft? A Post With An Unconfirmed Result May Already Be Published.</p><Button type="button" variant="destructive" onClick={() => { void draft.clear().then(() => { publication.current = undefined; setLocked(false); setText(""); setMedia(undefined); setError(undefined); setDiscardRequested(false); }).catch(() => setError("Draft Could Not Be Cleared")); }}>Discard Draft</Button><Button type="button" variant="outline" onClick={() => setDiscardRequested(false)}>Keep Draft</Button></div> : <Button type="button" variant="outline" onClick={() => setDiscardRequested(true)}>Start A New Draft</Button> : null}
          {altWarning ? <div role="alert" className="rounded-xl border p-3 text-sm"><p>This Attachment Has No Alt Text. Add A Description Before Posting.</p><Button type="button" variant="outline" onClick={() => setAltWarning(false)}>Add Description</Button><Button type="button" onClick={() => void publish(true)}>Post Without Description</Button></div> : null}
          {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
          {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
          <DialogFooter><DialogClose disabled={pending} className="rounded-xl border px-3 py-2">Cancel</DialogClose><Button type="submit" disabled={pending || !draft.loaded || !valid || disabled}>{pending ? "Publishing…" : quote ? "Post Quote" : "Post Reply"}</Button></DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
    {published ? <p role="status" className="mt-2 text-xs text-muted-foreground">{quote ? "Quote Post Published" : "Reply Published"}</p> : null}
  </>;
}
