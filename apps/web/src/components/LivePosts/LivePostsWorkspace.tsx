"use client";

import { useEffect, useState } from "react";
import { Plus, RefreshCw } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { useLivePosts } from "@/hooks/useLivePosts";
import { liveEventPhase, type AtmoEvent } from "@/lib/livePosts/atmoEventClient";
import type { LiveUpdateAttachmentsDraft } from "@/lib/livePosts/livePostMedia";
import type { ComposeLinkPreview } from "@/lib/blueskyExternalEmbed";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { livePostErrorMessage } from "@/lib/livePosts/livePostErrorMessage";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialPermissionRecovery } from "@/components/Social/SocialPermissionRecovery";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogTitle } from "@/components/ui/dialog";
import { LivePostUpdateComposer } from "./LivePostUpdateComposer";
import { LivePostNewEventDialog, type LivePostNewEventInput } from "./LivePostNewEventDialog";
import { LivePostHistory } from "./LivePostHistory";
import { LivePostEventSections, type LivePostSidebarRow } from "./LivePostEventSections";

const destinationLabels = { blog: "Blog", bluesky: "Bluesky", both: "Blog and Bluesky" };

export function LivePostsWorkspace() {
  const { session } = useAuth();
  return session ? <LivePostsViewer key={session.did} /> : <p className="p-6">Log In to Use Live Post.</p>;
}

function LivePostsViewer() {
  const live = useLivePosts();
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 60_000);
    return () => window.clearInterval(timer);
  }, []);
  const [selectedUri, setSelectedUri] = useState<string>();
  const [newEvent, setNewEvent] = useState(false);
  const [initialEvent, setInitialEvent] = useState<Partial<LivePostNewEventInput>>();
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [failure, setFailure] = useState<string>();
  const [attachments, setAttachments] = useState<Record<string, LiveUpdateAttachmentsDraft>>({});
  const [confirmEndUri, setConfirmEndUri] = useState<string>();
  const [endFailure, setEndFailure] = useState<string>();
  const event = live.events.find(value => value.uri === selectedUri) ?? live.events[0];
  const text = event ? drafts[event.uri] ?? "" : "";
  const failureSource = failure ?? live.error ?? live.publicationsError;
  const error = failureSource ? typeof failureSource === "string" ? failureSource : livePostErrorMessage(failureSource) : undefined;
  async function create(input: LivePostNewEventInput) {
    const created = await live.createEvent(input);
    setSelectedUri(created.uri); setNewEvent(false); setFailure(undefined);
  }
  async function publish(linkPreview?: ComposeLinkPreview) {
    if (!event || event.endedAt || live.pending) return;
    const uri = event.uri;
    try {
      const media = { ...attachments[uri], ...(linkPreview ? { linkPreview } : {}) };
      await live.publishUpdate(uri, text, Object.keys(media).length ? media : undefined);
      setDrafts(previous => ({ ...previous, [uri]: "" }));
      setAttachments(previous => ({ ...previous, [uri]: {} }));
      setFailure(undefined);
    }
    catch (failure) { setFailure(livePostErrorMessage(failure)); }
  }
  async function end() {
    if (!confirmEndUri || live.pending) return;
    try { await live.endEvent(confirmEndUri); setConfirmEndUri(undefined); setEndFailure(undefined); setFailure(undefined); }
    catch (failure) { setEndFailure(livePostErrorMessage(failure)); }
  }
  function select(uri: string) { setSelectedUri(uri); setFailure(undefined); }
  function openNew(source?: AtmoEvent) {
    setInitialEvent(source ? { title: source.title, tags: [], sourceEvent: { uri: source.uri, cid: source.cid }, startsAt: source.startsAt, endsAt: source.endsAt } : undefined);
    setNewEvent(true);
  }
  const linkedSources = new Set(live.events.flatMap(row => row.sourceEvent ? [row.sourceEvent.uri] : []));
  const rows: LivePostSidebarRow[] = [
    ...live.events.map(row => ({ key: row.uri, title: row.title, description: `${destinationLabels[row.destination]} · ${row.entries.length} Updates${row.endedAt ? " · Ended" : ""}`, section: liveEventPhase(row, now), selected: row.uri === event?.uri, onSelect: () => select(row.uri) })),
    ...live.rsvpEvents.filter(row => !linkedSources.has(row.uri)).map(row => ({ key: row.uri, title: row.title, description: `atmo.rsvp${row.startsAt ? ` · ${new Date(row.startsAt).toLocaleString()}` : ""}`, section: liveEventPhase(row, now), selected: false, onSelect: () => openNew(row) })),
  ];
  const rsvpError = live.rsvpError ? socialErrorMessage(live.rsvpError) : undefined;
  return <div className="flex min-h-0 min-w-0 flex-1 flex-col">
    <FeedHeader title="Live Post" subtitle="Live Events"><Button size="sm" disabled={live.pending || live.loading} onClick={() => openNew()}><Plus className="size-4" />New Event</Button><Button variant="ghost" size="icon" aria-label="Refresh Live Events" disabled={live.pending || live.loading} onClick={() => { void live.refresh(); }}><RefreshCw className="size-4" /></Button></FeedHeader>
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain lg:overflow-hidden">
      <div className="grid w-full gap-4 p-4 pt-0 lg:h-full lg:min-h-0 lg:grid-cols-[minmax(0,1fr)_18rem] lg:grid-rows-[minmax(0,1fr)]">
        <aside aria-label="Live Events" className={`${floatingGlassClasses} min-w-0 p-3 lg:min-h-0 lg:col-start-2 lg:row-start-1 lg:overflow-y-auto lg:overscroll-contain`}>
          <h2 className="mb-3 px-2 text-sm font-semibold">Your Events</h2>
          {live.loading || live.rsvpLoading ? <p role="status" className="p-2 text-sm">Loading Events…</p> : null}
          {rsvpError ? <div role="alert" className="mb-3 space-y-2 px-2 text-xs"><p>{rsvpError}</p>{rsvpError === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button variant="outline" size="sm" disabled={live.pending} onClick={() => { void live.refresh(); }}>Retry RSVP Events</Button>}</div> : null}
          <LivePostEventSections rows={rows} pending={live.pending} />
        </aside>
        <section aria-label="Live Event Workspace" className="min-w-0 lg:min-h-0 lg:col-start-1 lg:row-start-1 lg:overflow-y-auto lg:overscroll-contain">
          {error ? <div role="alert" className="mb-4 space-y-2 rounded-xl border p-3 text-sm"><p>{error}</p>{error === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : <Button size="sm" variant="outline" disabled={live.pending} onClick={() => { setFailure(undefined); void live.refresh(); }}>Retry Loading</Button>}</div> : null}
          {!event ? <div className={`${floatingGlassClasses} flex min-h-60 flex-col items-center justify-center gap-3 p-6 text-center`}><h2 className="text-lg font-semibold">Start a Live Event</h2><p className="max-w-sm text-sm text-muted-foreground">Publish updates to a new blog article, a Bluesky thread, or both.</p><Button disabled={live.pending || live.loading} onClick={() => openNew()}>New Event</Button></div> : <>
            <header className="mb-4 space-y-2"><div className="flex flex-wrap items-center justify-between gap-3"><h2 className="break-words text-2xl font-semibold">{event.title}</h2>{!event.endedAt ? <Button variant="outline" disabled={live.pending} onClick={() => { setEndFailure(undefined); setConfirmEndUri(event.uri); }}>End Live Post</Button> : null}</div><p className="text-sm text-muted-foreground">{destinationLabels[event.destination]}</p>{event.tags.length ? <p className="break-words text-xs text-muted-foreground">{event.tags.map(tag => `#${tag}`).join(" ")}</p> : null}</header>
            {event.endedAt ? <p role="status" className={`${floatingGlassClasses} mb-6 p-4 text-sm`}>Live Post Ended. Published Updates Remain Available.</p> : <LivePostUpdateComposer key={event.uri} event={event} text={text} onTextChange={value => setDrafts(previous => ({ ...previous, [event.uri]: value }))} attachments={attachments[event.uri] ?? {}} onAttachmentsChange={value => setAttachments(previous => ({ ...previous, [event.uri]: value }))} pending={live.pending} failure={failure} onPublish={publish} />}
            <LivePostHistory event={event} />
          </>}
        </section>
      </div>
    </div>
    <Dialog open={!!confirmEndUri} onOpenChange={open => { if (!open && !live.pending) { setConfirmEndUri(undefined); setEndFailure(undefined); } }}>
      <DialogContent showCloseButton={!live.pending}>
        <DialogTitle>End Live Post?</DialogTitle>
        <DialogDescription>This closes the live post session. Published updates stay available, and you cannot publish more updates to this session.</DialogDescription>
        {confirmEndUri && (drafts[confirmEndUri]?.trim() || Object.keys(attachments[confirmEndUri] ?? {}).length) ? <p className="text-sm">You have an unpublished draft. It will not be published when you end this live post.</p> : null}
        {endFailure ? <div role="alert" className="space-y-2 text-sm text-destructive"><p>{endFailure}</p>{endFailure === SCOPE_RECOVERY_MESSAGE ? <SocialPermissionRecovery /> : null}</div> : null}
        <DialogFooter><DialogClose disabled={live.pending} className="rounded-xl border px-3 py-2">Cancel</DialogClose><Button disabled={live.pending} onClick={() => { void end(); }}>{live.pending ? "Ending…" : "Confirm End Live Post"}</Button></DialogFooter>
      </DialogContent>
    </Dialog>
    <LivePostNewEventDialog key={`${newEvent ? "open" : "closed"}:${initialEvent?.sourceEvent?.uri ?? "custom"}`} initialEvent={initialEvent} open={newEvent} onOpenChange={setNewEvent} publications={live.publications} publicationsLoading={live.publicationsLoading} pending={live.pending} onCreate={create} />
  </div>;
}
