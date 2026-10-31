"use client";

import { toolsEnabled } from "@/lib/toolsEnabled";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { SquarePen } from "lucide-react";
import type { AppBskyDraftDefs } from "@atproto/api";
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
import { newThreadPublication, publishBlueskyThread, validThreadText, type ThreadPublication, type ThreadSegment } from "@/lib/blueskyThreadClient";
import type { ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { useSocialComposerDraft } from "@/hooks/useSocialComposerDraft";
import { removeUnavailableDraftMedia, replaceSocialDraftMedia } from "@/lib/socialDraftConversion";
import { missingMediaAlt } from "@/lib/composerMedia";
import { useAuth } from "@/hooks/useAuth";
import { createBlueskyPost } from "@/lib/blueskyComposeClient";
import { composerErrorMessage } from "@/lib/composerErrorMessage";
import { isMissingOAuthScope, SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { SocialPermissionRecovery } from "./SocialPermissionRecovery";
import { handlePostComposerShortcut } from "@/lib/postComposerShortcut";

type SocialComposeButtonProps = {
  initialDraft?: AppBskyDraftDefs.DraftView;
  autoOpen?: boolean;
  hideTrigger?: boolean;
  onClose?: () => void;
  onDraftChanged?: () => void;
};

export function SocialComposeButton(props: SocialComposeButtonProps = {}) {
  const { session } = useAuth();
  return session ? <SocialAccountComposeButton key={`${session.did}:${props.initialDraft?.id ?? "new"}`} {...props} /> : null;
}

function SocialAccountComposeButton({ initialDraft, autoOpen = false, hideTrigger = false, onClose, onDraftChanged }: SocialComposeButtonProps) {
  const { session, getOAuthSession } = useAuth();
  const { isPro: proAccess } = useProEntitlements();
  const toolsAvailable = toolsEnabled();
  const isPro = toolsAvailable && proAccess;
  const cache = useQueryClient();
  const accounts = useBrandAccounts(session?.did ?? "");
  const [selectedActor, setSelectedActor] = useState<string>();
  const actorDid = isPro ? selectedActor ?? session?.did : session?.did;
  const [open, setOpen] = useState(autoOpen);
  const scheduler = useSkejScheduling(session?.did ?? "", session?.did ?? "", { enabled: toolsAvailable && open && actorDid === session?.did, includeSchedules: false });
  const [mode, setMode] = useState<"now" | "schedule">("now");
  const [scheduledAt, setScheduledAt] = useState("");
  const [scheduled, setScheduled] = useState(false);
  const [segments, setSegments] = useState<ThreadSegment[]>([{ id: "first", text: "" }]);
  const previewResolvers = useRef(new Map<string, () => Promise<ComposeLinkPreview | undefined>>());
  const [removedPreviews, setRemovedPreviews] = useState<Record<string, string | undefined>>({});
  const [discardRequested, setDiscardRequested] = useState(false);
  const publication = useRef<ThreadPublication | undefined>(undefined);
  const [completed, setCompleted] = useState(0);
  const [locked, setLocked] = useState(false);
  const [mediaProgress, setMediaProgress] = useState<string>();
  const [altWarning, setAltWarning] = useState(false);
  const draft = useSocialComposerDraft({
    ownerDid: session?.did ?? "",
    session: getOAuthSession(),
    enabled: open,
    initialDraft,
    segments,
    publicationRef: publication,
    restore: restored => {
      setSegments(restored);
      setLocked(!!publication.current?.segments.some(item => item.attempted));
      setCompleted(publication.current?.segments.filter(item => item.result).length ?? 0);
    },
    onChanged: () => {
      void cache.invalidateQueries({ queryKey: ["socialDrafts", session?.did ?? ""] });
      onDraftChanged?.();
    },
  });
  function resetDraft() { setAltWarning(false); setRemovedPreviews({}); setLocked(false); setDiscardRequested(false); setMode("now"); setScheduledAt(""); setSegments([{ id: "first", text: "" }]); publication.current = undefined; publishedRef.current = false; setPublished(false); setCompleted(0); }
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
  const closing = useRef(false);
  const publishedRef = useRef(false);
  const [published, setPublished] = useState(false);
  const currentDid = useRef(session?.did);
  useLayoutEffect(() => {
    currentDid.current = session?.did;
    return () => { currentDid.current = undefined; };
  }, [session?.did]);
  const unsupportedDraftSettings = draft.unsupportedPublishSettings;
  const valid = !draft.completed && !published && !draft.hasUnavailableMedia && !unsupportedDraftSettings && segments.every(segment => validThreadText(segment.text, segment.media));

  async function changeOpen(value: boolean) {
    if (busy.current || closing.current) return;
    if (value) {
      setSelectedActor(session?.did); setScheduled(false); setPosted(false);
      setOpen(true);
      return;
    }
    closing.current = true;
    try {
      if (draft.loaded) await draft.close();
      setOpen(false);
      if (!publication.current?.segments.some(item => item.attempted)) resetDraft();
      onClose?.();
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : "Your Draft Could Not Be Saved. Retry Before Closing.");
    } finally { closing.current = false; }
  }

  async function retryDraftSync() {
    try {
      await draft.retry();
      if (draft.completed || published) {
        setOpen(false);
        resetDraft();
        onClose?.();
      }
    } catch { /* The hook retains the recovery error and local copy. */ }
  }

  function removeUnavailableAttachments() {
    setSegments(previous => previous.map(removeUnavailableDraftMedia));
  }

  async function publish(allowMissingAlt = false) {
    if (busy.current || publishedRef.current || !valid || !session || !draft.loaded) return;
    if (mode === "schedule" && segments.some(segment => segment.media)) { setError("Attachments Are Not Yet Supported For Scheduled Posts. Choose Post Now."); return; }
    if (!allowMissingAlt && !publication.current?.segments.some(item => item.attempted) && segments.some(segment => missingMediaAlt(segment.media))) { setAltWarning(true); return; }
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
      const snapshot = await draft.beginPublication();
      assertCurrentAccount();
      const previews = publication.current ? [] : await Promise.all(snapshot.map(async segment => {
        if (segment.media) return undefined;
        const resolved = await previewResolvers.current.get(segment.id)?.();
        // Native drafts may attach a link independently of their text. Preserve
        // that attachment unless the user explicitly removed its preview.
        return resolved ?? (segment.removedLinkUrl !== segment.linkPreview?.uri ? segment.linkPreview : undefined);
      }));
      const linkPreview = previews[0];
      assertCurrentAccount();
      if (isPro && mode === "schedule") {
        const instant = scheduledInstant(scheduledAt);
        if (!instant || !scheduler.readiness.data?.connected) throw new Error("Scheduling Is Not Ready.");
        await scheduler.schedule(snapshot[0].text, instant, linkPreview);
        assertCurrentAccount();
      } else if (segments.length > 1) {
        publication.current ??= newThreadPublication(did, snapshot.map((segment, index) => ({ ...segment, linkPreview: previews[index] })));
        setLocked(true);
        await publishBlueskyThread({ session: oauth, publication: publication.current, assertCurrentAccount, onProgress: setCompleted, onMediaProgress: setMediaProgress, checkpoint: draft.checkpoint });
      } else {
        publication.current ??= newThreadPublication(did, [{ ...snapshot[0], linkPreview }]);
        setLocked(true);
        await createBlueskyPost({ session: oauth, text: snapshot[0].text, linkPreview, media: snapshot[0].media, assertCurrentAccount, publication: publication.current, checkpoint: draft.checkpoint, onMediaProgress: setMediaProgress });
      }
      if (currentDid.current !== did) return;
      publishedRef.current = true; setPublished(true);
      await draft.complete();
      setOpen(false);
      resetDraft();
      setScheduled((isPro && mode === "schedule"));
      setPosted(true);
      onClose?.();
      void cache.invalidateQueries({ predicate: query => query.queryKey[0] === "blueskySocial" && query.queryKey[1] === did && ["timeline", "profileTimeline"].includes(String(query.queryKey[2])) });
    } catch (failure) {
      if (publication.current && !publication.current.segments.some(segment => segment.attempted)) { publication.current = undefined; setLocked(false); }
      if (currentDid.current === did && publication.current?.segments.some(segment => segment.result)) void cache.invalidateQueries({ predicate: query => query.queryKey[0] === "blueskySocial" && query.queryKey[1] === did && ["timeline", "profileTimeline"].includes(String(query.queryKey[2])) });
      if (currentDid.current === did) setError(composerErrorMessage(failure, segments.length > 1));
    } finally {
      draft.endPublication();
      busy.current = false;
      setPending(false); setMediaProgress(undefined);
    }
  }

  if (!session) return null;
  return <div className="absolute bottom-4 right-4 z-20 flex flex-col items-end gap-2 sm:bottom-6 sm:right-6">
    {posted ? <p role="status" className="animate-out fade-out-0 rounded-xl border bg-popover/95 px-3 py-2 text-sm shadow-sm duration-300 [animation-delay:3s] [animation-fill-mode:forwards] motion-reduce:animate-none">{scheduled ? "Post Scheduled" : "Post Published"}</p> : null}
    <Dialog open={open} onOpenChange={value => { void changeOpen(value); }}>
      {!hideTrigger ? <DialogTrigger aria-label="Compose Post" className="inline-flex size-14 items-center justify-center rounded-full border border-primary/30 bg-primary text-primary-foreground shadow-lg transition-colors hover:bg-primary/90 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring"><SquarePen aria-hidden="true" className="size-6" /></DialogTrigger> : null}
      <DialogContent className="max-h-[calc(100dvh-2rem)] overflow-y-auto sm:max-w-lg" showCloseButton={!pending}>
        <DialogTitle>{initialDraft ? segments.length > 1 ? "Edit Thread Draft" : "Edit Post Draft" : segments.length > 1 ? "New Thread" : "New Post"}</DialogTitle>
        <DialogDescription>{actorDid === session.did ? "Posts and Threads Autosave Privately Across Your Devices." : "Share a Post on Bluesky"}</DialogDescription>
        {toolsAvailable ? <SocialComposeAccountPicker ownerDid={session.did} accounts={accounts} actorDid={actorDid!} disabled={pending || locked} onChange={did => { setSelectedActor(did); setError(undefined); }} /> : null}
        {actorDid !== session.did ? <SocialBrandComposeContent key={`${session.did}:${actorDid}`} ownerDid={session.did} actorDid={actorDid!} onPendingChange={value => { busy.current = value; setPending(value); }} close={() => { void changeOpen(false); }} onPublished={wasScheduled => { setOpen(false); setScheduled(wasScheduled); setPosted(true); }} /> : <form key={session.did} className="flex min-w-0 flex-col gap-3" onKeyDown={handlePostComposerShortcut} onSubmit={event => { event.preventDefault(); void publish(); }}>
          {segments.map((segment, index) => <SocialThreadSegment key={segment.id} savedPreview={segment.linkPreview} text={segment.text} index={index} total={segments.length} disabled={pending || locked || !draft.loaded} mediaDisabled={mode === "schedule"} media={segment.media} updateMedia={change => setSegments(previous => previous.map(item => item.id === segment.id ? replaceSocialDraftMedia(item, change(item.media)) : item))} session={getOAuthSession()} open={open} onChange={value => setSegments(previous => previous.map(item => item.id === segment.id ? { ...item, text: value } : item))} onMove={direction => moveSegment(index, direction)} onDelete={() => setSegments(previous => previous.filter(item => item.id !== segment.id))} removedUrl={removedPreviews[segment.id] ?? segment.removedLinkUrl} rememberRemovedUrl={url => { setRemovedPreviews(previous => ({ ...previous, [segment.id]: url })); setSegments(previous => previous.map(item => item.id === segment.id ? { ...item, removedLinkUrl: url } : item)); }} registerPreview={resolve => { if (resolve) previewResolvers.current.set(segment.id, resolve); else previewResolvers.current.delete(segment.id); }} />)}
          <Button type="button" variant="outline" disabled={pending || locked || !draft.loaded || mode === "schedule"} onClick={() => setSegments(previous => [...previous, { id: crypto.randomUUID(), text: "" }])}>Add Post</Button>
          {segments.length > 1 ? <p className="text-xs text-muted-foreground">Threads Publish in Order. Each Post Replies to the Previous Post.</p> : null}
          {locked ? <p role="status" className="text-sm text-muted-foreground">{completed} of {segments.length} Posts Published. Retry Continues This Thread.</p> : null}
          {locked && !pending ? discardRequested ? <div className="rounded-xl border p-3 text-sm"><p>Discard the Remaining Draft? Published Posts Will Stay on Bluesky. A Post With an Unconfirmed Result May Also Have Published.</p><div className="mt-2 flex gap-2"><Button type="button" variant="destructive" onClick={() => { void draft.clear().then(() => { resetDraft(); setError(undefined); }).catch(() => setError("Draft Could Not Be Cleared")); }}>Discard Remaining Draft</Button><Button type="button" variant="outline" onClick={() => setDiscardRequested(false)}>Keep Draft</Button></div></div> : <Button type="button" variant="outline" onClick={() => setDiscardRequested(true)}>{segments.length > 1 ? "Start a New Thread" : "Start A New Post"}</Button> : null}
          {isPro && segments.length === 1 ? <ScheduleTimingControls mode={mode} value={scheduledAt} disabled={pending || locked || !draft.loaded} onModeChange={setMode} onChange={setScheduledAt} /> : !isPro && toolsAvailable ? <p className="text-xs text-muted-foreground">Multi-account support and scheduling require Pro.</p> : null}
          {(isPro && mode === "schedule") ? <SchedulingReadiness connected={scheduler.readiness.data?.connected} pending={scheduler.readiness.isPending} failed={scheduler.readiness.isError} connectUrl={scheduler.connectUrl} retry={() => { void scheduler.readiness.refetch(); }} /> : null}
          {!draft.loaded ? <p role="status">Restoring Draft…</p> : <p role="status" aria-live="polite" className="text-xs text-muted-foreground">{draft.saving ? "Saving Draft…" : draft.status}</p>}
          {draft.pendingCleanups ? <div role="status" className="text-sm text-muted-foreground">Post Published. Draft Cleanup Will Retry.<Button type="button" variant="outline" disabled={pending} onClick={() => { void draft.retryCleanups().catch(() => {}); }}>Retry Draft Cleanup</Button></div> : null}
          {draft.completed || published ? <Button type="button" variant="outline" disabled={pending || draft.saving} onClick={() => { void retryDraftSync(); }}>Finish Draft Cleanup</Button> : null}
          {draft.hasUnavailableMedia ? <div role="alert" className="space-y-2 rounded-xl border p-3 text-sm"><p>Some Attachments Are Unavailable. Retry Loading Private Photos, Reattach Them on the Original Device, or Remove Them Here.</p><Button type="button" variant="outline" disabled={pending || locked} onClick={removeUnavailableAttachments}>Remove Unavailable Attachments</Button></div> : null}
          {unsupportedDraftSettings ? <p role="alert" className="text-sm text-muted-foreground">This Draft Has Quote, Language, Content Label, or Audience Settings That This Composer Cannot Publish Yet. Continue in the Original App to Keep Those Settings.</p> : null}
          {draft.syncError ? <div role="alert" className="space-y-2 text-sm text-destructive"><p>{draft.syncError}</p><Button type="button" variant="outline" disabled={draft.saving} onClick={() => { void retryDraftSync(); }}>Retry Draft Sync</Button>{(isMissingOAuthScope(new Error(draft.syncError)) || draft.syncError === SCOPE_RECOVERY_MESSAGE) ? <SocialPermissionRecovery /> : null}</div> : null}
          {draft.hasConflict ? <div className="flex flex-wrap gap-2"><Button type="button" variant="outline" disabled={pending || draft.saving || locked} onClick={() => { void draft.forkLocal().catch(() => {}); }}>Keep Local As Separate Draft</Button><Button type="button" variant="outline" disabled={pending || draft.saving || locked} onClick={() => { void draft.openRemote().catch(() => {}); }}>Open Remote Version</Button></div> : null}
          {draft.storageError ? <div role="alert" className="text-sm text-destructive">{draft.storageError}<Button type="button" variant="outline" onClick={() => void draft.checkpoint().catch(() => {})}>Retry Saving Draft</Button></div> : null}
          {mediaProgress ? <p role="status">{mediaProgress}</p> : null}
          {altWarning ? <div role="alert" className="rounded-xl border p-3 text-sm"><p>Some Attachments Have No Alt Text. Add Descriptions Before Posting.</p><Button type="button" variant="outline" onClick={() => setAltWarning(false)}>Add Descriptions</Button><Button type="button" onClick={() => void publish(true)}>Post Without Descriptions</Button></div> : null}
          {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
          {error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}
          <DialogFooter><DialogClose disabled={pending} className="rounded-xl border px-3 py-2">Cancel</DialogClose><Button type="submit" disabled={pending || !draft.loaded || !valid || (isPro && mode === "schedule") && (!scheduledInstant(scheduledAt) || !scheduler.readiness.data?.connected || segments.some(segment => segment.media))}>{pending ? (isPro && mode === "schedule") ? "Scheduling…" : segments.length > 1 ? `Publishing ${completed + 1} of ${segments.length}…` : "Publishing…" : (isPro && mode === "schedule") ? "Schedule Post" : segments.length > 1 ? locked ? "Retry Remaining Posts" : "Post Thread" : "Post"}</Button></DialogFooter>
        </form>}
      </DialogContent>
    </Dialog>
  </div>;
}
