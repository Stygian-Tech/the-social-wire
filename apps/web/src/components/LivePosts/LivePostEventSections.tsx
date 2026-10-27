"use client";

import { ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";

export type LivePostSidebarRow = {
  key: string;
  title: string;
  description: string;
  startsAt?: string;
  endsAt?: string;
  section: "current" | "upcoming" | "past";
  selected: boolean;
  onSelect: () => void;
};

export function LivePostEventSections({ rows, pending }: { rows: LivePostSidebarRow[]; pending: boolean }) {
  return <nav aria-label="Event List" className="space-y-2">
    {([['current', 'Current'], ['upcoming', 'Upcoming'], ['past', 'Past']] as const).map(([section, label]) => {
      const matches = rows.filter(row => row.section === section);
      return <details key={section} open={section !== "past"} className="group/event-section">
        <summary className="flex cursor-pointer list-none items-center gap-2 rounded-lg px-2 py-2 text-sm font-medium hover:bg-accent [&::-webkit-details-marker]:hidden"><ChevronRight aria-hidden className="size-3.5 shrink-0 transition-transform group-open/event-section:rotate-90" /><span>{label}</span><span className="ml-auto text-xs text-muted-foreground">{matches.length}</span></summary>
        <div className="flex flex-col gap-1 pt-1">{matches.length ? matches.map(row => <Button key={row.key} variant={row.selected ? "secondary" : "ghost"} aria-current={row.selected ? "page" : undefined} className="h-auto justify-start whitespace-normal py-2 text-left" disabled={pending} onClick={row.onSelect}><span className="min-w-0"><span className="block break-words font-medium">{row.title}</span><span className="block text-xs text-muted-foreground">{row.description}</span></span></Button>) : <p className="px-2 py-2 text-xs text-muted-foreground">No {label} Events.</p>}</div>
      </details>;
    })}
  </nav>;
}
