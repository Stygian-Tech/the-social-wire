"use client";
import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { SportsSchedulePanel } from "@/components/SportsSchedulePanel";
import { useSpringStyle } from "@/hooks/useSpringStyle";
import { TooltipProvider } from "@/components/ui/tooltip";
import { SportsScheduleCard } from "@/components/SportsScheduleCard";
import { ChevronDown, ChevronUp } from "lucide-react";
import { useId, useMemo, useSyncExternalStore } from "react";
import { useCompactSportsSchedules } from "@/hooks/useCompactSportsSchedules";
import { useSportsDisplayLocale } from "@/hooks/useSportsDisplayLocale";
import { displaySportsEntityName } from "@/lib/sportsDisplayNames";
import { isDevDebugUiEnabled } from "@/lib/appEnv";
import { sportsEventHighlight } from "@/lib/sportsEventPresentation";
import { SportsStandingsDialog } from "@/components/SportsStandingsDialog";
import { useQuery } from "@tanstack/react-query";
import { getSportsEvents, type SportsEntity, type SportsSelection } from "@/lib/sportsFeedClient";

const compactStyles = (value: number) => {
  const compact = Math.min(1, Math.max(0, value));
  return { "--sports-full-row": `${1 - compact}fr`, "--sports-compact-row": `${compact}fr`, "--sports-full-opacity": String(1 - compact), "--sports-compact-opacity": String(compact), "--sports-card-padding": `${8 - 4 * compact}px`, "--sports-body-min-height": `${176 - 96 * compact}px`, "--sports-skeleton-height": `${144 - 80 * compact}px` };
};

const transientScopes = new Map<string, string>();
const readStoredPresentation = (key: string) => {
  if (transientScopes.has(key)) return transientScopes.get(key);
  try { return window.localStorage.getItem(key); } catch { return undefined; }
};
const storePresentation = (key: string, value: string) => {
  try { window.localStorage.setItem(key, value); transientScopes.delete(key); } catch { transientScopes.set(key, value); }
  window.dispatchEvent(new window.Event("sports-schedule-scope"));
};
const subscribeScope = (callback: () => void) => {
  window.addEventListener("storage", callback);
  window.addEventListener("sports-schedule-scope", callback);
  return () => { window.removeEventListener("storage", callback); window.removeEventListener("sports-schedule-scope", callback); };
};

export function SportsEventsStrip({ feedID, hidden, entities = [], selections = [], viewerDID = "public", selectionsLoading = false, catalogLoading = false }: { feedID: string; hidden: boolean; entities?: SportsEntity[]; selections?: SportsSelection[]; viewerDID?: string; selectionsLoading?: boolean; catalogLoading?: boolean }) {
  const locale = useSportsDisplayLocale();
  const showDiagnostics = isDevDebugUiEnabled();
  const { section: sectionRef, compact } = useCompactSportsSchedules();
  const compactSpring = useSpringStyle(compact ? 1 : 0, compactStyles);
  const storageKey = `the-social-wire.sports-schedule-scope.v1:${viewerDID}`;
  const scope = useSyncExternalStore(subscribeScope, () => { const value = readStoredPresentation(storageKey); return value && ["teams", "sports", "leagues"].includes(value) ? value : "all"; }, () => "all");
  const expandedKey = `the-social-wire.sports-schedules-expanded.v1:${viewerDID}`;
  const expanded = useSyncExternalStore(subscribeScope, () => readStoredPresentation(expandedKey) !== "false", () => true);
  const bodyID = useId();
  const teamsOnly = scope === "teams";
  const entitiesByID = useMemo(() => new Map(entities.map(entity => [entity.id, entity])), [entities]);
  const { teamIDs, allPreferredIDs } = useMemo(() => {
    const muted = new Set(selections.filter(selection => selection.action === "mute").map(selection => selection.reference));
    const follows = selections.filter(selection => selection.action === "follow" && !muted.has(selection.reference));
    const teamIDs = [...new Set(follows.filter(selection => ["team", "ncaa-team", "national-side"].includes(entitiesByID.get(selection.reference)?.kind ?? "")).map(selection => selection.reference))].sort();
    const allPreferredIDs = [...new Set(follows.filter(selection => entitiesByID.get(selection.reference)?.active).map(selection => selection.reference))].sort();
    return { teamIDs, allPreferredIDs };
  }, [selections, entitiesByID]);
  const waitingForInterests = selectionsLoading || catalogLoading;
  const contextLabels = useMemo(() => {
    const labels = new Map<string, string>();
    for (const entity of entities) {
      const sport = entity.sportID ? entitiesByID.get(entity.sportID) : undefined;
      const name = displaySportsEntityName(entity, locale);
      // Long competition labels need normal word boundaries inside narrow cards.
      // Short names such as Formula 1 retain their nonbreaking presentation.
      const competitionLabel = name.length > 20 ? name.replaceAll("\u00a0", " ") : name;
      labels.set(entity.id, [sport ? displaySportsEntityName(sport, locale) : undefined, competitionLabel].filter(Boolean).join(" · "));
    }
    return labels;
  }, [entities, entitiesByID, locale]);
  const contextLabel = (competitionID: string) => contextLabels.get(competitionID) ?? "";
  const preferredIDs = useMemo(() => {
    const followedTeams = new Set(teamIDs);
    return allPreferredIDs.filter(id => {
      const entity = entitiesByID.get(id);
      return scope === "all" || (scope === "teams" ? followedTeams.has(id) : scope === "sports" ? entity?.kind === "sport" : ["competition", "classification", "conference", "group"].includes(entity?.kind ?? ""));
    });
  }, [allPreferredIDs, teamIDs, entitiesByID, scope]);
  const emptyScope = scope !== "all" && !waitingForInterests && !preferredIDs.length;
  const scopeName = scope === "sports" ? "sports" : scope === "leagues" ? "leagues or competitions" : "teams";
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const events = useQuery({ queryKey: ["sportsEvents", feedID, viewerDID, scope, teamsOnly ? teamIDs : "all", preferredIDs, timeZone], queryFn: ({ signal }) => getSportsEvents(feedID, signal, teamsOnly ? teamIDs : undefined, { preferredIDs, timeZone }), enabled: !emptyScope && !waitingForInterests, staleTime: 5 * 60000, refetchInterval: 5 * 60000, retry: 1 });
  const data = waitingForInterests || emptyScope ? undefined : events.data;
  const eventRows = useMemo(() => data?.events.map(event => ({ event, highlight: hidden ? undefined : sportsEventHighlight(event, events.dataUpdatedAt, timeZone) })) ?? [], [data?.events, hidden, events.dataUpdatedAt, timeZone]);
  const scheduleRange = useMemo(() => {
    const timestamps = data?.events.map(event => Date.parse(event.startsAt)) ?? [];
    return timestamps.length ? [new Date(Math.min(...timestamps)).toLocaleDateString(), new Date(Math.max(...timestamps)).toLocaleDateString()] : [];
  }, [data?.events]);
  return <section ref={element => { sectionRef.current = element; compactSpring(element); }} data-topic-topbar data-compact={compact} aria-label="Sports Events" className={`sticky top-2 z-20 m-2 shrink-0 p-3 ${floatingGlassClasses}`}>
    <div className="mb-2 flex items-center justify-between gap-3 text-sm">
      <h2 className="min-w-0 font-medium [overflow-wrap:anywhere]">Schedules and Results</h2>
      <div className="flex items-center gap-2">
      {!hidden && !emptyScope && (data?.standings?.length || data?.bracketSources?.length) ? <SportsStandingsDialog tables={data?.standings ?? []} bracketSources={data?.bracketSources ?? []} contextLabel={contextLabel} teamsOnly={teamsOnly} /> : null}
      <label className="relative flex items-center"><span className="sr-only">Schedule Scope</span><select aria-label="Schedule Scope" value={scope} onChange={event => storePresentation(storageKey, event.target.value)} className="min-h-9 appearance-none rounded-md border bg-background py-1 pl-3 pr-9 text-foreground"><option value="all">{allPreferredIDs.length ? "Your Sports" : "All Sports"}</option><option value="sports">My Sports</option><option value="leagues">My Leagues</option><option value="teams">My Teams</option></select><ChevronDown aria-hidden="true" className="pointer-events-none absolute right-3 size-4 text-muted-foreground" /></label><button type="button" aria-label={expanded ? "Collapse Schedules" : "Expand Schedules"} aria-expanded={expanded} aria-controls={bodyID} onClick={() => storePresentation(expandedKey, String(!expanded))} className="flex size-9 shrink-0 items-center justify-center rounded-md border hover:bg-muted focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring">{expanded ? <ChevronUp aria-hidden="true" className="size-4" /> : <ChevronDown aria-hidden="true" className="size-4" />}</button></div>
    </div>
    <SportsSchedulePanel id={bodyID} expanded={expanded}><div data-schedule-body style={!data && !emptyScope && !events.isError ? { minHeight: "var(--sports-body-min-height,176px)" } : undefined}>
    {emptyScope ? <p className="text-sm text-muted-foreground">{scope === "teams" ? "Follow a team to see its schedule here." : `Follow ${scopeName} to see their schedules and standings here.`}</p> : !data ? <p role="status" className="text-sm text-muted-foreground">{events.isError ? "Schedules Unavailable" : "Loading Schedules…"}</p> : !data.events.length ? <p className="text-sm text-muted-foreground">{scope !== "all" ? `No upcoming or recent events for your followed ${scopeName} in this feed.` : "No upcoming or recent events in this feed."}</p> : null}
    {!emptyScope && !data && !events.isError ? <div aria-hidden="true" className="mt-2 flex gap-3 overflow-hidden">{[0,1,2].map(id => <div key={id} className="w-52 shrink-0 rounded-md border bg-muted/40" style={{ height: "var(--sports-skeleton-height,144px)" }} />)}</div> : null}
    {data?.events.length ? <TooltipProvider delay={150}><div className="flex items-stretch gap-3 overflow-x-auto">{eventRows.map(({ event, highlight }) => <SportsScheduleCard key={event.id} event={event} compact={compact} hidden={hidden} highlight={highlight} contextLabel={contextLabel(event.competitionID)} />)}</div></TooltipProvider> : null}
    <div className="grid" style={{ gridTemplateRows: "var(--sports-full-row,1fr)", opacity: "var(--sports-full-opacity,1)" }} aria-hidden={compact}><div className="min-h-0 overflow-hidden">
    {showDiagnostics && data?.events.length ? <p className="mt-2 text-xs text-muted-foreground">{data.events.length} Fixtures{data.eventsLimited ? " (Serving Limit Reached)" : ""} · {scheduleRange[0]} – {scheduleRange[1]} · Provider coverage varies by competition.</p> : null}
    {!emptyScope && data ? showDiagnostics ? <p className="mt-2 text-xs text-muted-foreground">{data.updatedAt ? <>{data.degraded ? "Cached Events · " : "Updated "}{new Date(data.updatedAt).toLocaleTimeString()} · </> : null}<a href="https://www.thesportsdb.com/" target="_blank" rel="noopener noreferrer" className="underline">TheSportsDB</a></p> : <p className="mt-2 flex min-w-0 max-w-full items-baseline gap-1 whitespace-nowrap text-xs text-muted-foreground"><a href="https://www.thesportsdb.com/" target="_blank" rel="noopener noreferrer" className="shrink-0 underline">TheSportsDB</a><span className="min-w-0 truncate" title="Coverage Varies By Competition.">· Coverage Varies By Competition.</span><span className="sr-only">{data.degraded ? " Cached event data." : ""}{data.updatedAt ? ` Last updated ${new Date(data.updatedAt).toLocaleString()}.` : " Update time unavailable."}</span></p> : null}
    </div></div>
    </div></SportsSchedulePanel>
  </section>;
}
