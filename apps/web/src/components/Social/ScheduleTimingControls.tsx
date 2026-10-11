"use client";

import { scheduledInstant } from "@/components/ContentCalendar/calendarDates";

export function ScheduleTimingControls({ mode, value, disabled, onModeChange, onChange }: { mode: "now" | "schedule"; value: string; disabled: boolean; onModeChange: (mode: "now" | "schedule") => void; onChange: (value: string) => void }) {
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  return <div className="space-y-2">
    <div className="flex gap-2" aria-label="Publishing Time">{(["now", "schedule"] as const).map(option => <button key={option} type="button" disabled={disabled} aria-pressed={mode === option} className={`rounded-xl border px-3 py-1.5 text-sm ${mode === option ? "bg-accent" : "hover:bg-accent"}`} onClick={() => onModeChange(option)}>{option === "now" ? "Post Now" : "Schedule"}</button>)}</div>
    {mode === "schedule" ? <><label className="block space-y-1 text-sm"><span>Publish At</span><input aria-label="Publish At" type="datetime-local" value={value} disabled={disabled} onChange={event => onChange(event.target.value)} className="w-full rounded-xl border bg-background px-3 py-2" /></label><p className="text-xs text-muted-foreground">{timezone} · At Least One Minute From Now</p>{value && !scheduledInstant(value) ? <p role="alert" className="text-xs text-destructive">Choose a Valid Future Time.</p> : null}</> : null}
  </div>;
}
