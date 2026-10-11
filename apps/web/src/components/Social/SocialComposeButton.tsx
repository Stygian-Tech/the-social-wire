"use client";

import { useEffect, useRef, useState } from "react";
import { SquarePen } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { createBlueskyPost, postTextLength } from "@/lib/blueskyComposeClient";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { SocialPeopleTextField } from "./SocialPeopleTextField";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";

export function SocialComposeButton() {
  const { session, getOAuthSession } = useAuth();
  const cache = useQueryClient();
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [posted, setPosted] = useState(false);
  const busy = useRef(false);
  const currentDid = useRef(session?.did);
  useEffect(() => {
    currentDid.current = session?.did;
    return () => { currentDid.current = undefined; };
  }, [session?.did]);
  const { graphemes: length, bytes } = postTextLength(text);
  const valid = !!text.trim() && length <= 300 && bytes <= 3000;

  function changeOpen(value: boolean) {
    if (busy.current) return;
    if (value) { setText(""); setError(undefined); setPosted(false); }
    setOpen(value);
  }

  async function publish() {
    if (busy.current || !valid || !session) return;
    const did = session.did;
    busy.current = true;
    setPending(true);
    setError(undefined);
    try {
      const oauth = getOAuthSession();
      if (!oauth) throw new Error(SCOPE_RECOVERY_MESSAGE);
      const assertCurrentAccount = () => {
        if (currentDid.current !== did || getOAuthSession()?.did !== did || oauth.did !== did) throw new Error("Your account changed. Please reopen the composer.");
      };
      await createBlueskyPost({ session: oauth, text, assertCurrentAccount });
      if (currentDid.current !== did) return;
      setOpen(false);
      setText("");
      setPosted(true);
      void cache.invalidateQueries({ predicate: query => query.queryKey[0] === "blueskySocial" && query.queryKey[1] === did && ["timeline", "profileTimeline"].includes(String(query.queryKey[2])) });
    } catch (failure) {
      if (currentDid.current === did) setError(socialErrorMessage(failure) === SCOPE_RECOVERY_MESSAGE ? SCOPE_RECOVERY_MESSAGE : "Your post could not be published. Please try again.");
    } finally {
      busy.current = false;
      setPending(false);
    }
  }

  if (!session) return null;
  return <div className="absolute bottom-4 right-4 z-20 flex flex-col items-end gap-2 sm:bottom-6 sm:right-6">
    {posted ? <p role="status" className="rounded-xl border bg-popover/95 px-3 py-2 text-sm shadow-sm">Post Published</p> : null}
    <Dialog open={open} onOpenChange={changeOpen}>
      <DialogTrigger aria-label="Compose Post" className="inline-flex size-14 items-center justify-center rounded-full border border-primary/30 bg-primary text-primary-foreground shadow-lg transition-colors hover:bg-primary/90 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring"><SquarePen aria-hidden="true" className="size-6" /></DialogTrigger>
      <DialogContent className="sm:max-w-lg" showCloseButton={!pending}>
        <DialogTitle>New Post</DialogTitle>
        <DialogDescription>Share a Post on Bluesky</DialogDescription>
        <form className="flex min-w-0 flex-col gap-3" onSubmit={event => { event.preventDefault(); void publish(); }}>
          <label htmlFor="social-compose-text" className="sr-only">Post Text</label>
          <SocialPeopleTextField id="social-compose-text" autoFocus value={text} disabled={pending} onValueChange={setText} rows={6} placeholder="What's Happening?" className="w-full resize-y rounded-xl border bg-background p-3 text-base leading-relaxed" />
          <p aria-live="polite" className={`text-right text-sm ${length > 300 ? "text-destructive" : "text-muted-foreground"}`}>{length}/300</p>
          {bytes > 3000 ? <p className="text-sm text-destructive">Post Text Exceeds the Size Limit</p> : null}
          {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
          {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
          <DialogFooter><DialogClose disabled={pending} className="rounded-xl border px-3 py-2">Cancel</DialogClose><Button type="submit" disabled={pending || !valid}>{pending ? "Publishing…" : "Post"}</Button></DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  </div>;
}
