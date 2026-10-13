"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { SquarePen } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { useSkejScheduling } from "@/hooks/useSkejScheduling";
import { scheduledInstant } from "@/components/ContentCalendar/calendarDates";
import { ScheduleTimingControls } from "./ScheduleTimingControls";
import { SchedulingReadiness } from "./SchedulingReadiness";
import { useProEntitlements } from "@/hooks/useProEntitlements";
import { useBrandAccounts } from "@/hooks/useBrandAccounts";
import { getStoredOAuthDid } from "@/lib/auth";
import { SocialComposeAccountPicker } from "./SocialComposeAccountPicker";
import { SocialBrandComposeContent } from "./SocialBrandComposeContent";
import { useComposeLinkPreview } from "@/hooks/useComposeLinkPreview";
import { SocialComposeLinkCard } from "./SocialComposeLinkCard";
import { useAuth } from "@/hooks/useAuth";
import { createBlueskyPost, postTextLength } from "@/lib/blueskyComposeClient";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { SocialComposePreview } from "./SocialComposePreview";
import { SocialPeopleTextField } from "./SocialPeopleTextField";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { handlePostComposerShortcut } from "@/lib/postComposerShortcut";

export function SocialComposeButton() {
  const { session } = useAuth();
  return session ? <SocialAccountComposeButton key={session.did} /> : null;
}

function SocialAccountComposeButton() {
  const { session, getOAuthSession } = useAuth();
  const { isPro } = useProEntitlements();
  const cache = useQueryClient();
  const accounts = useBrandAccounts(session?.did ?? "");
  const [selectedActor, setSelectedActor] = useState<string>();
  const actorDid = isPro ? selectedActor ?? session?.did : session?.did;
  const [open, setOpen] = useState(false);
  const scheduler = useSkejScheduling(session?.did ?? "", session?.did ?? "", { enabled: open && actorDid === session?.did, includeSchedules: false });
  const [mode, setMode] = useState<"now" | "schedule">("now");
  const [scheduledAt, setScheduledAt] = useState("");
  const [scheduled, setScheduled] = useState(false);
  const [text, setText] = useState("");
  const link = useComposeLinkPreview(text, getOAuthSession(), open);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [posted, setPosted] = useState(false);
  useEffect(() => {
    if (!posted) return;
    const timer = setTimeout(() => setPosted(false), 3300);
    return () => clearTimeout(timer);
  }, [posted]);
  const busy = useRef(false);
  const currentDid = useRef(session?.did);
  useLayoutEffect(() => {
    currentDid.current = session?.did;
    return () => { currentDid.current = undefined; };
  }, [session?.did]);
  const { graphemes: length, bytes } = postTextLength(text);
  const valid = !!text.trim() && length <= 300 && bytes <= 3000;

  function changeOpen(value: boolean) {
    if (busy.current) return;
    if (value) { link.reset(); setSelectedActor(session?.did); setMode("now"); setScheduledAt(""); setScheduled(false); setText(""); setError(undefined); setPosted(false); }
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
        if (currentDid.current !== did || getStoredOAuthDid() !== did || getOAuthSession()?.did !== did || oauth.did !== did) throw new Error("Your account changed. Please reopen the composer.");
      };
      assertCurrentAccount();
      const linkPreview = link.needsResolution ? await link.resolve() : link.preview;
      assertCurrentAccount();
      if (isPro && mode === "schedule") {
        const instant = scheduledInstant(scheduledAt);
        if (!instant || !scheduler.readiness.data?.connected) throw new Error("Scheduling Is Not Ready.");
        await scheduler.schedule(text, instant, linkPreview);
        assertCurrentAccount();
      } else await createBlueskyPost({ session: oauth, text, linkPreview, assertCurrentAccount });
      if (currentDid.current !== did) return;
      setOpen(false);
      setText("");
      setScheduled((isPro && mode === "schedule"));
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
    {posted ? <p role="status" className="animate-out fade-out-0 rounded-xl border bg-popover/95 px-3 py-2 text-sm shadow-sm duration-300 [animation-delay:3s] [animation-fill-mode:forwards] motion-reduce:animate-none">{scheduled ? "Post Scheduled" : "Post Published"}</p> : null}
    <Dialog open={open} onOpenChange={changeOpen}>
      <DialogTrigger aria-label="Compose Post" className="inline-flex size-14 items-center justify-center rounded-full border border-primary/30 bg-primary text-primary-foreground shadow-lg transition-colors hover:bg-primary/90 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring"><SquarePen aria-hidden="true" className="size-6" /></DialogTrigger>
      <DialogContent className="sm:max-w-lg" showCloseButton={!pending}>
        <DialogTitle>New Post</DialogTitle>
        <DialogDescription>Share a Post on Bluesky</DialogDescription>
        <SocialComposeAccountPicker ownerDid={session.did} accounts={accounts} actorDid={actorDid!} disabled={pending} onChange={did => { setSelectedActor(did); setText(""); setError(undefined); }} />
        {actorDid !== session.did ? <SocialBrandComposeContent key={`${session.did}:${actorDid}`} ownerDid={session.did} actorDid={actorDid!} onPendingChange={value => { busy.current = value; setPending(value); }} close={() => changeOpen(false)} onPublished={wasScheduled => { setOpen(false); setScheduled(wasScheduled); setPosted(true); }} /> : <form key={session.did} className="flex min-w-0 flex-col gap-3" onKeyDown={handlePostComposerShortcut} onSubmit={event => { event.preventDefault(); void publish(); }}>
          <label htmlFor="social-compose-text" className="sr-only">Post Text</label>
          <SocialPeopleTextField id="social-compose-text" autoFocus value={text} disabled={pending} onValueChange={setText} rows={6} placeholder="What's Happening?" className="w-full resize-y rounded-xl border bg-background p-3 text-base leading-relaxed" />
          <SocialComposePreview text={text} />
          <SocialComposeLinkCard {...link} disabled={pending} />
          <p aria-live="polite" className={`text-right text-sm ${length > 300 ? "text-destructive" : "text-muted-foreground"}`}>{length}/300</p>
          {bytes > 3000 ? <p className="text-sm text-destructive">Post Text Exceeds the Size Limit</p> : null}
          {isPro ? <ScheduleTimingControls mode={mode} value={scheduledAt} disabled={pending} onModeChange={setMode} onChange={setScheduledAt} /> : <p className="text-xs text-muted-foreground">Multi-account support and scheduling require Pro.</p>}
          {(isPro && mode === "schedule") ? <SchedulingReadiness connected={scheduler.readiness.data?.connected} pending={scheduler.readiness.isPending} failed={scheduler.readiness.isError} connectUrl={scheduler.connectUrl} retry={() => { void scheduler.readiness.refetch(); }} /> : null}
          {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
          {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
          <DialogFooter><DialogClose disabled={pending} className="rounded-xl border px-3 py-2">Cancel</DialogClose><Button type="submit" disabled={pending || !valid || (isPro && mode === "schedule") && (!scheduledInstant(scheduledAt) || !scheduler.readiness.data?.connected)}>{pending ? (isPro && mode === "schedule") ? "Scheduling…" : "Publishing…" : (isPro && mode === "schedule") ? "Schedule Post" : "Post"}</Button></DialogFooter>
        </form>}
      </DialogContent>
    </Dialog>
  </div>;
}
