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
import { SocialThreadSegment } from "./SocialThreadSegment";
import { newThreadPublication, publishBlueskyThread, validThreadText, type ThreadPublication } from "@/lib/blueskyThreadClient";
import type { ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { useAuth } from "@/hooks/useAuth";
import { createBlueskyPost } from "@/lib/blueskyComposeClient";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
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
  const [segments, setSegments] = useState([{ id: "first", text: "" }]);
  const text = segments[0].text;
  const previewResolvers = useRef(new Map<string, () => Promise<ComposeLinkPreview | undefined>>());
  const [removedPreviews, setRemovedPreviews] = useState<Record<string, string | undefined>>({});
  const [discardRequested, setDiscardRequested] = useState(false);
  const publication = useRef<ThreadPublication | undefined>(undefined);
  const [completed, setCompleted] = useState(0);
  const [locked, setLocked] = useState(false);
  function resetDraft() { setRemovedPreviews({}); setLocked(false); setDiscardRequested(false); setMode("now"); setScheduledAt(""); setSegments([{ id: "first", text: "" }]); publication.current = undefined; setCompleted(0); }
  function moveSegment(index: number, direction: -1 | 1) {
    setSegments(previous => { const next = [...previous]; [next[index], next[index + direction]] = [next[index + direction], next[index]]; return next; });
  }
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
  const valid = segments.every(segment => validThreadText(segment.text));

  function changeOpen(value: boolean) {
    if (busy.current) return;
    if (value) { setSelectedActor(session?.did); setScheduled(false); setPosted(false); }
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
      const previews = publication.current ? [] : await Promise.all(segments.map(segment => previewResolvers.current.get(segment.id)?.()));
      const linkPreview = previews[0];
      assertCurrentAccount();
      if (isPro && mode === "schedule") {
        const instant = scheduledInstant(scheduledAt);
        if (!instant || !scheduler.readiness.data?.connected) throw new Error("Scheduling Is Not Ready.");
        await scheduler.schedule(text, instant, linkPreview);
        assertCurrentAccount();
      } else if (segments.length > 1) {
        publication.current ??= newThreadPublication(did, segments.map((segment, index) => ({ ...segment, linkPreview: previews[index] })));
        setLocked(true);
        await publishBlueskyThread({ session: oauth, publication: publication.current, assertCurrentAccount, onProgress: setCompleted });
      } else await createBlueskyPost({ session: oauth, text, linkPreview, assertCurrentAccount });
      if (currentDid.current !== did) return;
      setOpen(false);
      resetDraft();
      setScheduled((isPro && mode === "schedule"));
      setPosted(true);
      void cache.invalidateQueries({ predicate: query => query.queryKey[0] === "blueskySocial" && query.queryKey[1] === did && ["timeline", "profileTimeline"].includes(String(query.queryKey[2])) });
    } catch (failure) {
      if (publication.current && !publication.current.segments.some(segment => segment.attempted)) { publication.current = undefined; setLocked(false); }
      if (currentDid.current === did && publication.current?.segments.some(segment => segment.result)) void cache.invalidateQueries({ predicate: query => query.queryKey[0] === "blueskySocial" && query.queryKey[1] === did && ["timeline", "profileTimeline"].includes(String(query.queryKey[2])) });
      if (currentDid.current === did) setError(socialErrorMessage(failure) === SCOPE_RECOVERY_MESSAGE ? SCOPE_RECOVERY_MESSAGE : segments.length > 1 ? "Your Thread Could Not Be Finished. Retry to Continue Without Reposting Published Posts." : "Your post could not be published. Please try again.");
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
      <DialogContent className="max-h-[calc(100dvh-2rem)] overflow-y-auto sm:max-w-lg" showCloseButton={!pending}>
        <DialogTitle>{segments.length > 1 ? "New Thread" : "New Post"}</DialogTitle>
        <DialogDescription>Share a Post on Bluesky</DialogDescription>
        <SocialComposeAccountPicker ownerDid={session.did} accounts={accounts} actorDid={actorDid!} disabled={pending || locked} onChange={did => { setSelectedActor(did); setError(undefined); }} />
        {actorDid !== session.did ? <SocialBrandComposeContent key={`${session.did}:${actorDid}`} ownerDid={session.did} actorDid={actorDid!} onPendingChange={value => { busy.current = value; setPending(value); }} close={() => changeOpen(false)} onPublished={wasScheduled => { setOpen(false); setScheduled(wasScheduled); setPosted(true); }} /> : <form key={session.did} className="flex min-w-0 flex-col gap-3" onKeyDown={handlePostComposerShortcut} onSubmit={event => { event.preventDefault(); void publish(); }}>
          {segments.map((segment, index) => <SocialThreadSegment key={segment.id} text={segment.text} index={index} total={segments.length} disabled={pending || locked} session={getOAuthSession()} open={open} onChange={value => setSegments(previous => previous.map(item => item.id === segment.id ? { ...item, text: value } : item))} onMove={direction => moveSegment(index, direction)} onDelete={() => setSegments(previous => previous.filter(item => item.id !== segment.id))} removedUrl={removedPreviews[segment.id]} rememberRemovedUrl={url => setRemovedPreviews(previous => ({ ...previous, [segment.id]: url }))} registerPreview={resolve => { if (resolve) previewResolvers.current.set(segment.id, resolve); else previewResolvers.current.delete(segment.id); }} />)}
          <Button type="button" variant="outline" disabled={pending || locked || mode === "schedule"} onClick={() => setSegments(previous => [...previous, { id: crypto.randomUUID(), text: "" }])}>Add Post</Button>
          {segments.length > 1 ? <p className="text-xs text-muted-foreground">Threads Publish in Order. Each Post Replies to the Previous Post.</p> : null}
          {locked ? <p role="status" className="text-sm text-muted-foreground">{completed} of {segments.length} Posts Published. Retry Continues This Thread.</p> : null}
          {locked && !pending ? discardRequested ? <div className="rounded-xl border p-3 text-sm"><p>Discard the Remaining Draft? Published Posts Will Stay on Bluesky. A Post With an Unconfirmed Result May Also Have Published.</p><div className="mt-2 flex gap-2"><Button type="button" variant="destructive" onClick={() => { resetDraft(); setError(undefined); }}>Discard Remaining Draft</Button><Button type="button" variant="outline" onClick={() => setDiscardRequested(false)}>Keep Draft</Button></div></div> : <Button type="button" variant="outline" onClick={() => setDiscardRequested(true)}>Start a New Thread</Button> : null}
          {isPro && segments.length === 1 ? <ScheduleTimingControls mode={mode} value={scheduledAt} disabled={pending} onModeChange={setMode} onChange={setScheduledAt} /> : !isPro ? <p className="text-xs text-muted-foreground">Multi-account support and scheduling require Pro.</p> : null}
          {(isPro && mode === "schedule") ? <SchedulingReadiness connected={scheduler.readiness.data?.connected} pending={scheduler.readiness.isPending} failed={scheduler.readiness.isError} connectUrl={scheduler.connectUrl} retry={() => { void scheduler.readiness.refetch(); }} /> : null}
          {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
          {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
          <DialogFooter><DialogClose disabled={pending} className="rounded-xl border px-3 py-2">Cancel</DialogClose><Button type="submit" disabled={pending || !valid || (isPro && mode === "schedule") && (!scheduledInstant(scheduledAt) || !scheduler.readiness.data?.connected)}>{pending ? (isPro && mode === "schedule") ? "Scheduling…" : segments.length > 1 ? `Publishing ${completed + 1} of ${segments.length}…` : "Publishing…" : (isPro && mode === "schedule") ? "Schedule Post" : segments.length > 1 ? locked ? "Retry Remaining Posts" : "Post Thread" : "Post"}</Button></DialogFooter>
        </form>}
      </DialogContent>
    </Dialog>
  </div>;
}
