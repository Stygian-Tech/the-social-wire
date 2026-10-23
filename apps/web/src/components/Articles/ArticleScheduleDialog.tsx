"use client";

import { useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { localDateTimeValue, scheduledInstant } from "@/components/ContentCalendar/calendarDates";

export function ArticleScheduleDialog({ title, save, close }: { title: string; save: (instant: string) => Promise<void>; close: () => void }) {
  const [minimum] = useState(() => localDateTimeValue(new Date(Date.now() + 60_000)));
  const [value, setValue] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const writing = useRef(false);
  async function submit() {
    const instant = scheduledInstant(value);
    if (!instant || writing.current) return;
    writing.current = true; setPending(true); setError(undefined);
    try { await save(instant); close(); }
    catch (failure) { setError(failure instanceof Error ? failure.message : "Article Could Not Be Scheduled."); }
    finally { writing.current = false; setPending(false); }
  }
  return <Dialog open onOpenChange={open => { if (!open && !pending) close(); }}><DialogContent showCloseButton={!pending}><DialogTitle>Schedule Article?</DialogTitle><DialogDescription>Skej stores the full article in a public schedule record immediately. Publication happens at the chosen time.</DialogDescription><p className="break-words text-sm">{title}</p><form className="space-y-3" onSubmit={event => { event.preventDefault(); void submit(); }}><label className="block space-y-1 text-sm"><span>Publish At</span><input aria-label="Publish Article At" type="datetime-local" min={minimum} value={value} disabled={pending} onChange={event => setValue(event.target.value)} className="w-full rounded-xl border bg-background p-2" /></label><p className="text-xs text-muted-foreground">At Least One Minute From Now · {Intl.DateTimeFormat().resolvedOptions().timeZone}</p>{error ? <p role="alert">{error}</p> : null}<div className="flex gap-2"><Button type="submit" disabled={pending || !scheduledInstant(value)}>{pending ? "Scheduling…" : "Confirm Schedule"}</Button><DialogClose disabled={pending} render={<Button variant="outline" />}>Cancel</DialogClose></div></form></DialogContent></Dialog>;
}
