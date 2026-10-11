"use client";

import { useId, useLayoutEffect, useRef, useState } from "react";
import { MessageCircle } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { AppBskyFeedPost, moderateProfile, type ModerationOpts, type AppBskyFeedDefs } from "@atproto/api";
import { useAuth } from "@/hooks/useAuth";
import { getStoredOAuthDid } from "@/lib/auth";
import { createBlueskyPost, postTextLength } from "@/lib/blueskyComposeClient";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { formatSocialEngagementCount } from "@/lib/formatSocialEngagementCount";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { SocialPeopleTextField } from "./SocialPeopleTextField";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";

export function SocialReplyButton({ post, className, moderation }: { post: AppBskyFeedDefs.PostView; className: string; moderation: ModerationOpts }) {
  const { session } = useAuth();
  return <SocialAccountReplyButton key={`${session?.did ?? ""}:${post.uri}`} post={post} className={className} moderation={moderation} />;
}

function SocialAccountReplyButton({ post, className, moderation }: { post: AppBskyFeedDefs.PostView; className: string; moderation: ModerationOpts }) {
  const { session, getOAuthSession } = useAuth();
  const cache = useQueryClient();
  const fieldId = useId();
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [published, setPublished] = useState(false);
  const busy = useRef(false);
  const currentDid = useRef(session?.did);
  useLayoutEffect(() => {
    currentDid.current = session?.did;
    return () => { currentDid.current = undefined; };
  }, [session?.did]);
  const { graphemes, bytes } = postTextLength(text);
  const valid = !!text.trim() && graphemes <= 300 && bytes <= 3000;
  const identity = moderateProfile(post.author, moderation).ui("displayName");
  const recipient = identity.filter || identity.blur || identity.noOverride ? "Account" : `@${post.author.handle}`;
  const disabled = !session || post.viewer?.replyDisabled || !AppBskyFeedPost.validateRecord(post.record).success;

  function changeOpen(value: boolean) {
    if (busy.current) return;
    if (value) { setText(""); setError(undefined); setPublished(false); }
    setOpen(value);
  }

  async function publish() {
    if (busy.current || disabled || !valid || !session) return;
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
      await createBlueskyPost({ session: oauth, text, replyTo: post, assertCurrentAccount });
      if (currentDid.current !== did) return;
      setOpen(false);
      setText("");
      setPublished(true);
      void cache.invalidateQueries({ predicate: query => query.queryKey[0] === "blueskySocial" && query.queryKey[1] === did && ["thread", "timeline", "profileTimeline", "explore", "bookmarks", "notifications"].includes(String(query.queryKey[2])) });
    } catch (failure) {
      if (currentDid.current === did) setError(socialErrorMessage(failure));
    } finally {
      busy.current = false;
      if (currentDid.current === did) setPending(false);
    }
  }

  return <>
    <Dialog open={open} onOpenChange={changeOpen}>
      <DialogTrigger className={className} title={post.viewer?.replyDisabled ? "Replies Are Disabled" : `${post.replyCount ?? 0} Replies`} aria-label={`Reply (${post.replyCount ?? 0})`} disabled={disabled}><MessageCircle aria-hidden="true" className="size-4" /><span>{formatSocialEngagementCount(post.replyCount ?? 0)}</span></DialogTrigger>
      <DialogContent className="sm:max-w-lg" showCloseButton={!pending}>
        <DialogTitle>Reply</DialogTitle>
        <DialogDescription>Replying To {recipient}</DialogDescription>
        <form className="flex min-w-0 flex-col gap-3" onSubmit={event => { event.preventDefault(); void publish(); }}>
          <label htmlFor={fieldId} className="sr-only">Reply Text</label>
          <SocialPeopleTextField id={fieldId} autoFocus value={text} disabled={pending} onValueChange={setText} rows={5} placeholder="Write a Reply…" className="w-full resize-y rounded-xl border bg-background p-3 text-base leading-relaxed" />
          <p aria-live="polite" className={`text-right text-sm ${graphemes > 300 ? "text-destructive" : "text-muted-foreground"}`}>{graphemes}/300</p>
          {bytes > 3000 ? <p className="text-sm text-destructive">Reply Text Exceeds the Size Limit</p> : null}
          {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
          {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
          <DialogFooter><DialogClose disabled={pending} className="rounded-xl border px-3 py-2">Cancel</DialogClose><Button type="submit" disabled={pending || !valid || disabled}>{pending ? "Publishing…" : "Post Reply"}</Button></DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
    {published ? <p role="status" className="mt-2 text-xs text-muted-foreground">Reply Published</p> : null}
  </>;
}
