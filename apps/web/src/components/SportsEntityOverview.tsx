"use client";

import { useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { sportsEventHighlight, sportsEventStartLabel } from "@/lib/sportsEventPresentation";
import { useQuery } from "@tanstack/react-query";
import { SportsStandingsDialog } from "@/components/SportsStandingsDialog";
import { useSportsDisplayLocale } from "@/hooks/useSportsDisplayLocale";
import { displaySportsEntityName } from "@/lib/sportsDisplayNames";
import { getSportsEvents, type SportsEntity, type SportsEvent } from "@/lib/sportsFeedClient";

export function SportsEntityOverview({ feedID, entity, entities, hidden, eventsEnabled, viewerDID = "public" }: {
  feedID: string; entity: SportsEntity; entities: SportsEntity[]; hidden: boolean; eventsEnabled: boolean; viewerDID?: string;
}) {
  const locale = useSportsDisplayLocale();
  const [fixtureCount, setFixtureCount] = useState(6);
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  // Exact entity pages show that entity's coverage independently of broader interests.
  const query = useQuery({ queryKey: ["sportsEntityOverview", feedID, viewerDID, timeZone], queryFn: ({ signal }) => getSportsEvents(feedID, signal, undefined, { preferredIDs: [], timeZone }), enabled: eventsEnabled, staleTime: 5 * 60000, refetchInterval: 5 * 60000, retry: 1 });
  const data = eventsEnabled ? query.data : undefined;
  const entitiesByID = useMemo(() => new Map(entities.map(item => [item.id, item])), [entities]);
  const contextLabel = (competitionID: string) => {
    const competition = entitiesByID.get(competitionID);
    const sport = competition?.sportID ? entitiesByID.get(competition.sportID) : undefined;
    return [sport ? displaySportsEntityName(sport, locale) : undefined, competition ? displaySportsEntityName(competition, locale) : undefined].filter(Boolean).join(" · ");
  };
  const current = data?.events.filter(event => event.status === "in-progress").sort((a, b) => Date.parse(b.startsAt) - Date.parse(a.startsAt))[0];
  const latest = data?.events.filter(event => event.status === "finished" && Date.parse(event.startsAt) <= query.dataUpdatedAt).sort((a, b) => Date.parse(b.startsAt) - Date.parse(a.startsAt))[0];
  const featured = current ?? latest;
  const upcoming = data?.events.filter(event => ["scheduled", "postponed"].includes(event.status) && Date.parse(event.startsAt) >= query.dataUpdatedAt).sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt)) ?? [];
  const standingRows = data?.standings?.flatMap(table => {
    const rows = ["team", "ncaa-team", "national-side"].includes(entity.kind) ? table.rows.filter(row => row.entityID === entity.id) : table.rows.slice(0, 3);
    return rows.map(row => ({ table, row }));
  }) ?? [];
  const fixture = (event: SportsEvent, result: boolean) => {
    const highlight = hidden ? undefined : sportsEventHighlight(event, query.dataUpdatedAt, timeZone);
    return <article key={event.id} className={`min-w-48 flex-1 rounded-lg border p-3 ${highlight === "In Progress" ? "border-red-500 bg-red-500/10" : highlight ? "border-red-500/40 bg-red-500/5" : "bg-background"}`}>
    <p className="text-xs text-muted-foreground">{contextLabel(event.competitionID)}</p>
    <h3 className="mt-1 text-sm font-medium">{event.title}</h3>
    <time className="mt-1 block text-xs text-muted-foreground" dateTime={event.startsAt}>{sportsEventStartLabel(event)}</time>
    {!hidden && result ? <p className="mt-2 font-semibold">{event.homeScore != null || event.awayScore != null ? `${event.homeScore ?? "—"} – ${event.awayScore ?? "—"}` : "Score Unavailable"}</p> : null}
    {!hidden && event.status !== "scheduled" ? <p className="mt-1 text-xs text-muted-foreground">{event.status === "in-progress" ? "In Progress" : event.status === "finished" ? "Final" : event.status === "postponed" ? "Postponed" : event.status}</p> : null}
  </article>;
  };

  return <section aria-label={`${displaySportsEntityName(entity, locale)} Overview`} className="mb-7 space-y-4 rounded-xl border bg-muted/20 p-4">
    <div className="flex flex-wrap items-center justify-between gap-2"><h2 className="font-semibold">At a Glance</h2>{!hidden && (data?.standings?.length || data?.bracketSources?.length) ? <SportsStandingsDialog tables={data.standings ?? []} bracketSources={data.bracketSources ?? []} contextLabel={contextLabel} teamsOnly={false} /> : null}</div>
    {!eventsEnabled ? <p className="text-sm text-muted-foreground">Schedules and standings are not enabled. Matching articles are available below.</p> : !data && query.isError ? <p role="status" className="text-sm text-muted-foreground">Event coverage is unavailable. Matching articles remain available below.</p> : !data ? <p role="status" className="text-sm text-muted-foreground">Loading Event Coverage…</p> : <>
      {!hidden ? <div className="space-y-2"><h3 className="text-sm font-medium">{current ? "Current Event" : "Latest Result"}</h3>{featured ? fixture(featured, true) : <p className="text-sm text-muted-foreground">No current or recent result is available for this selection.</p>}</div> : <p className="text-xs text-muted-foreground">Scores and results are hidden. Article headlines and images may reveal results.</p>}
      <div className="space-y-2"><h3 className="text-sm font-medium">Upcoming Schedule</h3>{upcoming.length ? <div className="flex gap-3 overflow-x-auto pb-1">{upcoming.slice(0, fixtureCount).map(event => fixture(event, false))}</div> : <p className="text-sm text-muted-foreground">No upcoming fixtures are available for this selection.</p>}{upcoming.length > fixtureCount ? <Button variant="outline" size="sm" onClick={() => setFixtureCount(count => count + 6)}>Show More Fixtures</Button> : null}{upcoming.length ? <p className="text-xs text-muted-foreground">Showing {Math.min(fixtureCount, upcoming.length)} of {upcoming.length} Upcoming Fixtures{data.eventsLimited ? " · Provider Serving Limit Reached" : ""}</p> : null}</div>
      {!hidden ? <div className="space-y-2"><h3 className="text-sm font-medium">Standings Snapshot</h3>{standingRows.length ? <ul className="space-y-2">{standingRows.slice(0, 6).map(({ table, row }) => <li key={`${table.competitionID}:${table.season}:${row.id}`} className="flex flex-wrap justify-between gap-2 text-sm"><span>{row.rank != null ? `${row.rank}. ` : ""}{row.name}<span className="block text-xs text-muted-foreground">{contextLabel(table.competitionID)} · {table.season}</span></span><span>{row.points != null ? `${row.points} Points` : ""}</span></li>)}</ul> : <p className="text-sm text-muted-foreground">Standings are not available for this selection.</p>}</div> : null}
      <p className="text-xs text-muted-foreground">{data.degraded || query.isError ? "Cached Event Coverage · " : ""}{data.updatedAt ? <>Updated <time dateTime={data.updatedAt}>{new Date(data.updatedAt).toLocaleString()}</time> · </> : null}<a href="https://www.thesportsdb.com/" target="_blank" rel="noopener noreferrer" className="underline">TheSportsDB</a> · Coverage varies by competition.</p>
    </>}
  </section>;
}
