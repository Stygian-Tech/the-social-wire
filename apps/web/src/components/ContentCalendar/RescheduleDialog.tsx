"use client";

import { useRef, useState } from "react";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogFooter, DialogTitle } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { localDateTimeValue, scheduledInstant } from "./calendarDates";

export function RescheduleDialog({ initialTime, save, close }: { initialTime: string; save: (instant: string) => Promise<void>; close: () => void }) {
  const busy = useRef(false);
  const [value, setValue] = useState(() => { const date = new Date(initialTime); return Number.isFinite(date.getTime()) ? localDateTimeValue(date) : ""; });
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  async function submit() {
    const instant = scheduledInstant(value);
    if (!instant || busy.current) return;
    busy.current = true;
    setPending(true); setError(undefined);
    try { await save(instant); close(); } catch (failure) { setError(failure instanceof Error ? failure.message : "Schedule Could Not Be Updated."); } finally { busy.current = false; setPending(false); }
  }
  return <Dialog open onOpenChange={open => { if (!open && !pending) close(); }}><DialogContent showCloseButton={!pending}><DialogTitle>Reschedule Post</DialogTitle><DialogDescription>Choose a Future Time in {Intl.DateTimeFormat().resolvedOptions().timeZone}</DialogDescription><form className="space-y-3" onSubmit={event => { event.preventDefault(); void submit(); }}><label className="block space-y-1 text-sm"><span>Publish At</span><input aria-label="Publish At" type="datetime-local" className="w-full rounded-xl border bg-background p-2" disabled={pending} value={value} onChange={event => setValue(event.target.value)} /></label><p className="text-xs text-muted-foreground">At Least One Minute From Now</p>{error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}<DialogFooter><DialogClose disabled={pending} className="rounded-xl border px-3 py-2">Cancel</DialogClose><Button type="submit" disabled={pending || !scheduledInstant(value)}>{pending ? "Saving…" : "Save Time"}</Button></DialogFooter></form></DialogContent></Dialog>;
}
