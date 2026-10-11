"use client";

import { useState } from "react";
import { useSkejScheduling } from "@/hooks/useSkejScheduling";
import type { SkejScheduleSummary } from "@/lib/skej/skejSchedulingClient";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogTitle } from "@/components/ui/dialog";
import { SchedulingReadiness } from "@/components/Social/SchedulingReadiness";
import { CalendarMonth } from "./CalendarMonth";
import { localCalendarDate } from "./calendarDates";
import { RescheduleDialog } from "./RescheduleDialog";

export function ContentCalendarAccount({ ownerDid, actorDid }: { ownerDid: string; actorDid: string }) {
  const scheduler = useSkejScheduling(ownerDid, actorDid);
  const [month, setMonth] = useState(() => new Date());
  const [day, setDay] = useState(() => localCalendarDate(new Date()));
  const [editing, setEditing] = useState<SkejScheduleSummary>();
  const [canceling, setCanceling] = useState<SkejScheduleSummary>();
  const [error, setError] = useState<string>();
  const items = (scheduler.schedules.data ?? []).filter(item => item.did === actorDid);
  const counts: Record<string, number> = {};
  for (const item of items) { const date = new Date(item.scheduledAt); if (Number.isFinite(date.getTime())) { const key = localCalendarDate(date); counts[key] = (counts[key] ?? 0) + 1; } }
  const selected = items.filter(item => { const date = new Date(item.scheduledAt); return Number.isFinite(date.getTime()) && localCalendarDate(date) === day; }).sort((a, b) => a.scheduledAt.localeCompare(b.scheduledAt));
  async function cancel() {
    if (!canceling || scheduler.pending) return;
    setError(undefined);
    try { await scheduler.cancel(canceling); setCanceling(undefined); } catch (failure) { setError(failure instanceof Error ? failure.message : "Schedule Could Not Be Canceled."); }
  }
  return <div className="mx-auto w-full max-w-5xl space-y-4">
    <div className="flex flex-wrap items-center justify-between gap-3"><SchedulingReadiness connected={scheduler.readiness.data?.connected} pending={scheduler.readiness.isPending} failed={scheduler.readiness.isError} connectUrl={scheduler.connectUrl} retry={() => { void scheduler.readiness.refetch(); }} /><Button size="sm" variant="outline" disabled={scheduler.schedules.isFetching || scheduler.pending} onClick={() => { void scheduler.schedules.refetch(); void scheduler.readiness.refetch(); }}>Refresh</Button></div>
    {scheduler.schedules.isError ? <p role="alert" className="rounded-xl border border-destructive/40 p-3 text-sm">Scheduled Posts Could Not Be Loaded. <button className="underline" onClick={() => { void scheduler.schedules.refetch(); }}>Retry</button></p> : null}
    {scheduler.readiness.data?.connected && scheduler.schedules.isPending ? <p role="status" className="text-sm text-muted-foreground">Loading Scheduled Posts…</p> : null}
    <CalendarMonth month={month} selectedDay={day} counts={counts} onMonthChange={setMonth} onSelectDay={setDay} />
    <section className="space-y-3"><h2 className="font-semibold">{new Date(`${day}T12:00:00`).toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric", year: "numeric" })}</h2>
      {!selected.length && scheduler.readiness.data?.connected && !scheduler.schedules.isPending && !scheduler.schedules.isError ? <p className="py-6 text-center text-sm text-muted-foreground">No Posts Scheduled for This Day</p> : null}
      {selected.map(item => <article key={item.scheduleUri} className="rounded-2xl border bg-card p-4"><header className="mb-2 flex flex-wrap items-center justify-between gap-2 text-sm"><time dateTime={item.scheduledAt}>{new Date(item.scheduledAt).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}</time><span className="rounded-full bg-muted px-2 py-0.5 capitalize">{item.status.replaceAll("_", " ")}</span></header>{item.record.posts.map((post, index) => <p key={index} className="whitespace-pre-wrap break-words text-sm">{post.text}</p>)}{item.lastError?.message ? <p className="mt-2 text-sm text-destructive">{item.lastError.message}</p> : null}{["draft", "scheduled", "blocked", "failed"].includes(item.status) ? <div className="mt-3 flex gap-2"><Button size="sm" variant="outline" disabled={scheduler.pending} onClick={() => setEditing(item)}>Reschedule</Button><Button size="sm" variant="ghost" disabled={scheduler.pending} onClick={() => { setError(undefined); setCanceling(item); }}>Cancel Scheduled Post</Button></div> : null}</article>)}
    </section>
    {editing ? <RescheduleDialog key={editing.scheduleUri} initialTime={editing.scheduledAt} save={instant => scheduler.reschedule(editing, instant)} close={() => setEditing(undefined)} /> : null}
    <Dialog open={!!canceling} onOpenChange={value => { if (!value && !scheduler.pending) setCanceling(undefined); }}><DialogContent showCloseButton={!scheduler.pending}><DialogTitle>Cancel Scheduled Post?</DialogTitle><DialogDescription>This Post Will Not Be Published by Skej.</DialogDescription>{error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}<DialogFooter><DialogClose disabled={scheduler.pending} className="rounded-xl border px-3 py-2">Keep Scheduled</DialogClose><Button variant="destructive" disabled={scheduler.pending} onClick={() => { void cancel(); }}>{scheduler.pending ? "Canceling…" : "Cancel Scheduled Post"}</Button></DialogFooter></DialogContent></Dialog>
  </div>;
}
