"use client";
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { useState } from "react";
import type { SportsBracketSource, SportsStandings } from "@/lib/sportsFeedClient";
import { ArrowDown, ArrowUp, Flag, Trophy } from "lucide-react";

function ZoneIcon({ kind }: { kind: string }) {
  const Icon = kind === "relegation" ? ArrowDown : kind === "promotion" ? ArrowUp : kind === "qualification" || kind === "champion" ? Trophy : Flag;
  return <Icon aria-hidden="true" className="size-3.5 shrink-0" />;
}

export function SportsStandingsDialog({ tables, contextLabel, teamsOnly, bracketSources = [] }: { bracketSources?: SportsBracketSource[]; tables: SportsStandings[]; contextLabel: (competitionID: string) => string; teamsOnly: boolean }) {
  const [tab, setTab] = useState<"standings" | "brackets" | "sources">("standings");
  return <Dialog onOpenChange={open => { if (open) setTab("standings"); }}>
    <DialogTrigger render={<Button variant="outline" size="sm" />}>Standings</DialogTrigger>
    <DialogContent className="max-h-[80svh] overflow-y-auto sm:max-w-3xl">
      <DialogHeader><DialogTitle>Standings and Brackets</DialogTitle><DialogDescription>{teamsOnly ? "Full league tables for competitions with your followed teams in this feed. Official ranks are preserved." : "Competition standings for this feed."}</DialogDescription></DialogHeader>
      <div role="tablist" aria-label="Competition Tables" className="flex gap-2 border-b pb-2">{(["standings", "brackets", "sources"] as const).map(value => <button key={value} type="button" role="tab" id={`sports-${value}-tab`} aria-controls={`sports-${value}-panel`} aria-selected={tab === value} tabIndex={tab === value ? 0 : -1} onKeyDown={event => { if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) { event.preventDefault(); const tabs = ["standings", "brackets", "sources"] as const; const next = event.key === "Home" ? tabs[0] : event.key === "End" ? tabs[2] : tabs[(tabs.indexOf(tab) + (event.key === "ArrowRight" ? 1 : 2)) % tabs.length]; setTab(next); document.getElementById(`sports-${next}-tab`)?.focus(); } }} onClick={() => setTab(value)} className={`rounded-md px-3 py-2 text-sm ${tab === value ? "bg-accent text-accent-foreground" : "text-muted-foreground"}`}>{value === "standings" ? "Standings" : value === "brackets" ? "Brackets" : "Sources"}</button>)}</div>
      <div role="tabpanel" id="sports-standings-panel" aria-labelledby="sports-standings-tab" hidden={tab !== "standings"}>
      {!tables.length ? <p className="text-sm text-muted-foreground">No Standings Available for This Feed.</p> : null}
      {tables.map(table => <details key={`${table.competitionID}:${table.season}`} className="mt-3 text-sm">
      <summary className="cursor-pointer font-medium">{contextLabel(table.competitionID) || "Standings"}{table.season ? ` · ${table.season}` : ""}</summary>
      {table.status === "available" && table.rows.length ? <>
        <div className="overflow-x-auto"><table className="w-full text-left"><thead><tr>{["Rank", "Team", "Played", "Won", "Drawn", "Lost", "Points"].map(label => <th key={label} className="p-2 font-medium">{label}</th>)}</tr></thead><tbody>{table.rows.map(row => <tr key={row.id} className="border-t"><td className="p-2 tabular-nums">{row.rank ?? "—"}</td><th scope="row" className="p-2 font-normal">{row.name}{row.group ? <span className="block text-xs text-muted-foreground">{row.group}</span> : null}{row.zone ? <span className="mt-1 flex items-center gap-1 text-xs text-muted-foreground"><ZoneIcon kind={row.zone.kind} />{row.zone.label}</span> : null}</th>{[row.played, row.won, row.drawn, row.lost, row.points].map((value, index) => <td key={index} className="p-2 tabular-nums">{value ?? "—"}</td>)}</tr>)}</tbody></table></div>
        {table.rows.some(row => row.zone) ? <div className="mt-2 space-y-1 text-xs text-muted-foreground"><p>Marked places describe the current table, not a secured outcome.</p>{Array.from(new Map(table.rows.flatMap(row => row.zone ? [[`${row.zone.kind}:${row.zone.label}:${row.zone.sourceURL}`, row.zone] as const] : [])).values()).map(zone => <a key={`${zone.kind}:${zone.label}`} href={zone.sourceURL} target="_blank" rel="noopener noreferrer" className="flex items-center gap-1 underline"><ZoneIcon kind={zone.kind} />{zone.label} Rules</a>)}</div> : null}
      </> : <p className="text-muted-foreground">{table.status === "unavailable" ? "Standings Unavailable" : "No Standings Yet"}</p>}
      <p className="mt-1 text-xs text-muted-foreground">{table.degraded ? "Cached Standings · " : ""}{table.updatedAt ? <>Updated <time dateTime={table.updatedAt}>{new Date(table.updatedAt).toLocaleString()}</time> · </> : null}<a href={table.sourceURL} target="_blank" rel="noopener noreferrer" className="underline">Standings Source</a></p>
    </details>)}
      </div>
      <div role="tabpanel" id="sports-brackets-panel" aria-labelledby="sports-brackets-tab" hidden={tab !== "brackets"} className="space-y-3">
        <p className="text-sm text-muted-foreground">Open official brackets for confirmed matchups and series progress. Sources may cover a recently completed season.</p>
        {bracketSources.length ? bracketSources.map(source => <article key={source.id} className="rounded-md border p-3"><h3 className="font-medium">{source.title}</h3><p className="mb-2 text-xs text-muted-foreground">{contextLabel(source.competitionID)} · Season {source.season}</p><a aria-label={`Open Official Bracket for ${source.title}`} href={source.url} target="_blank" rel="noopener noreferrer" className="text-sm underline">Open Official Bracket<span className="sr-only"> for {source.title}</span></a></article>) : <p className="text-sm text-muted-foreground">No Reviewed Bracket Source for This Feed Yet.</p>}
      </div>
      <div role="tabpanel" id="sports-sources-panel" aria-labelledby="sports-sources-tab" hidden={tab !== "sources"} className="space-y-4">
        <p className="text-sm text-muted-foreground">Compare the competition and season with the linked source. Table updates show when we fetched the data; bracket review dates show when we reviewed the reference, not when its results changed.</p>
        <section className="space-y-2"><h3 className="font-medium">Standings Data</h3><p className="text-xs text-muted-foreground">Tables are supplied by TheSportsDB. Promotion and relegation rules have separate references below.</p>
          {tables.map(table => <article key={`${table.competitionID}:${table.season}`} className="rounded-md border p-3"><a href={table.sourceURL} target="_blank" rel="noopener noreferrer" className="text-sm underline">{contextLabel(table.competitionID) || "Competition"} · {table.season} · TheSportsDB</a><p className="mt-1 text-xs text-muted-foreground">{table.degraded ? "Cached Data · " : ""}{table.status === "unavailable" ? "Unavailable · " : ""}{table.updatedAt ? <>Fetched <time dateTime={table.updatedAt}>{new Date(table.updatedAt).toLocaleString()}</time></> : "No Fetch Timestamp Available"}</p></article>)}
          {!tables.length ? <p className="text-sm text-muted-foreground">No Standings Source for This Feed Yet.</p> : null}
        </section>
        <section className="space-y-2"><h3 className="font-medium">Table Rules</h3>{Array.from(new Map(tables.flatMap(table => table.rows.flatMap(row => row.zone ? [[row.zone.sourceURL, row.zone] as const] : []))).values()).map(zone => <a key={zone.sourceURL} href={zone.sourceURL} target="_blank" rel="noopener noreferrer" className="block text-sm underline">Rules Reference · {new URL(zone.sourceURL).hostname}</a>)}{!tables.some(table => table.rows.some(row => row.zone)) ? <p className="text-sm text-muted-foreground">No Place Rules Applied to These Tables.</p> : null}</section>
        <section className="space-y-2"><h3 className="font-medium">Official Bracket References</h3><p className="text-xs text-muted-foreground">These links open external official brackets. We do not serve live bracket data.</p>{bracketSources.map(source => <article key={source.id} className="rounded-md border p-3"><a href={source.url} target="_blank" rel="noopener noreferrer" className="text-sm underline">{source.title} · {source.season}</a><p className="mt-1 text-xs text-muted-foreground">{new URL(source.url).hostname} · Reviewed <time dateTime={source.reviewedAt}>{new Date(source.reviewedAt).toLocaleDateString(undefined, { timeZone: "UTC" })}</time></p></article>)}{!bracketSources.length ? <p className="text-sm text-muted-foreground">No Reviewed Bracket Source for This Feed Yet.</p> : null}</section>
      </div>
      <DialogClose render={<Button variant="outline" />}>Close</DialogClose>
    </DialogContent>
  </Dialog>;
}
