"use client";

import { CalendarDays } from "lucide-react";
import { Button } from "@/components/ui/button";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import type { LivePostSidebarRow } from "./LivePostEventSections";

type Props = {
  rows: LivePostSidebarRow[];
  loading: boolean;
  pending: boolean;
  onNewEvent: () => void;
};

export function LivePostSchedule({ rows, loading, pending, onNewEvent }: Props) {
  const scheduled = rows.filter(row => row.section !== "past").sort((a, b) =>
    (a.startsAt ? Date.parse(a.startsAt) : 0) - (b.startsAt ? Date.parse(b.startsAt) : 0));
  return <section aria-label="Live Post Schedule" className="space-y-5">
    <header className="space-y-2">
      <h2 className="text-2xl font-semibold">Live Post Schedule</h2>
      <p className="text-sm text-muted-foreground">Plan your next event or open a live post to publish updates. Past posts remain in Your Events.</p>
    </header>
    {loading ? <p role="status" className="p-4 text-sm">Loading Schedule…</p> : <>
      {!scheduled.length ? <div className={`${floatingGlassClasses} flex min-h-52 flex-col items-center justify-center gap-3 p-6 text-center`}>
        <CalendarDays aria-hidden className="size-8 text-muted-foreground" />
        <h3 className="text-lg font-semibold">No Live Events Scheduled</h3>
        <p className="max-w-sm text-sm text-muted-foreground">Create an event to publish updates to a blog article, a Bluesky thread, or both.</p>
        <Button disabled={pending} onClick={onNewEvent}>New Event</Button>
      </div> : null}
      {([['current', 'Current'], ['upcoming', 'Upcoming']] as const).map(([phase, label]) => {
        const matches = scheduled.filter(row => row.section === phase);
        return <section key={phase} aria-label={`${label} Schedule`} className="space-y-3">
          <h3 className="text-sm font-semibold">{label}</h3>
          {matches.length ? <ul className="space-y-3">{matches.map(row => <li key={row.key}>
            <Button variant="ghost" disabled={pending} onClick={row.onSelect} className={`${floatingGlassClasses} h-auto w-full justify-start whitespace-normal p-4 text-left`}>
              <span className="min-w-0 space-y-1">
                <span className="block break-words font-semibold">{row.title}</span>
                <span className="block text-xs text-muted-foreground">{row.startsAt ? <time dateTime={row.startsAt}>{new Date(row.startsAt).toLocaleString()}</time> : "No Scheduled Start"}{row.endsAt ? <> – <time dateTime={row.endsAt}>{new Date(row.endsAt).toLocaleString()}</time></> : null}</span>
                <span className="block text-xs text-muted-foreground">{row.description}</span>
              </span>
            </Button>
          </li>)}</ul> : <p className="text-sm text-muted-foreground">No {label} Events.</p>}
        </section>;
      })}
    </>}
  </section>;
}
