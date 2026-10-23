"use client";

import { useState } from "react";
import type { useSkejScheduling } from "@/hooks/useSkejScheduling";
import { isSkejArticleSchedule, type SkejScheduleSummary } from "@/lib/skej/skejSchedulingClient";
import { SchedulingReadiness } from "@/components/Social/SchedulingReadiness";
import { RescheduleDialog } from "@/components/ContentCalendar/RescheduleDialog";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";

export function ArticleScheduledList({ scheduler, isPro, onCanceled }: { scheduler: ReturnType<typeof useSkejScheduling>; isPro: boolean; onCanceled: (item: SkejScheduleSummary) => Promise<void> }) {
  const [editing, setEditing] = useState<SkejScheduleSummary>();
  const [canceling, setCanceling] = useState<SkejScheduleSummary>();
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);
  if (!isPro) return <p className="text-sm">Article Scheduling Requires Social Wire Pro.</p>;
  const items = (scheduler.schedules.data ?? []).filter(isSkejArticleSchedule);
  async function cancel() {
    if (!canceling || busy) return;
    setBusy(true); setError(undefined);
    try { await scheduler.cancel(canceling); await onCanceled(canceling); setCanceling(undefined); }
    catch (failure) { setError(failure instanceof Error ? failure.message : "Schedule Could Not Be Canceled."); }
    finally { setBusy(false); }
  }
  return <div className="space-y-3"><SchedulingReadiness connected={scheduler.readiness.data?.connected} pending={scheduler.readiness.isPending} failed={scheduler.readiness.isError} connectUrl={scheduler.connectUrl} retry={() => { void scheduler.readiness.refetch(); }} /><Button size="sm" variant="outline" disabled={scheduler.pending || scheduler.schedules.isFetching} onClick={() => { void scheduler.schedules.refetch(); void scheduler.readiness.refetch(); }}>Refresh Schedules</Button>{scheduler.schedules.isError ? <p role="alert">Scheduled Articles Could Not Be Loaded. Refresh to Retry.</p> : scheduler.readiness.data?.connected && scheduler.schedules.isPending ? <p role="status">Loading Scheduled Articles…</p> : scheduler.readiness.data?.connected && !items.length ? <p className="text-sm">No Scheduled Articles.</p> : null}{items.map(item => <article key={item.scheduleUri} className="space-y-2 rounded-xl border p-3 text-sm"><p className="break-words font-medium">{articleScheduleTitle(item)}</p><time dateTime={item.scheduledAt}>{new Date(item.scheduledAt).toLocaleString()}</time><p className="capitalize">{item.status.replaceAll("_", " ")}</p>{item.lastError?.message ? <p role="alert">{item.lastError.message}</p> : null}{["draft", "scheduled", "blocked", "failed"].includes(item.status) ? <div className="flex flex-wrap gap-2"><Button size="sm" variant="outline" disabled={scheduler.pending || busy} onClick={() => setEditing(item)}>Reschedule</Button><Button size="sm" variant="outline" disabled={scheduler.pending || busy} onClick={() => { setError(undefined); setCanceling(item); }}>Cancel Schedule</Button></div> : null}</article>)}{editing ? <RescheduleDialog initialTime={editing.scheduledAt} save={instant => scheduler.reschedule(editing, instant)} close={() => setEditing(undefined)} /> : null}<Dialog open={!!canceling} onOpenChange={open => { if (!open && !busy) setCanceling(undefined); }}><DialogContent showCloseButton={!busy}><DialogTitle>Cancel Scheduled Article?</DialogTitle><DialogDescription>Skej will not publish this article. The article content has already been shared in a public schedule record.</DialogDescription>{error ? <p role="alert">{error}</p> : null}<div className="flex gap-2"><Button variant="destructive" disabled={busy} onClick={() => { void cancel(); }}>Confirm Cancellation</Button><DialogClose disabled={busy} render={<Button variant="outline" />}>Keep Scheduled</DialogClose></div></DialogContent></Dialog></div>;
}

export function articleScheduleTitle(item: SkejScheduleSummary): string {
  return isSkejArticleSchedule(item) ? item.record.shadowRecord.title : "Scheduled Post";
}
