import type { SportsEvent } from "@/lib/sportsFeedClient";

// The provider has no endedAt field. Recent results use the fixture start,
// never its refresh timestamp, and persist for the fixture’s local calendar day.
export function sportsEventHighlight(event: SportsEvent, now: number, timeZone: string = "UTC"): "In Progress" | "Recent Result" | undefined {
  if (event.status === "in-progress") return "In Progress";
  if (event.status !== "finished") return;
  const startsAt = Date.parse(event.startsAt);
  if (!(startsAt <= now)) return;
  const day = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" });
  if (day.format(startsAt) === day.format(now)) return "Recent Result";
}


/** Missing provider time must be explicit; a midnight timestamp is a valid time. */
export function sportsEventStartLabel(event: SportsEvent): string {
  const date = new Date(event.startsAt);
  if (!Number.isFinite(date.getTime())) return "TBD";
  if (event.startTimeKnown === false) return `${date.toLocaleDateString([], { month: "short", day: "numeric", timeZone: "UTC" })} · TBD`;
  return date.toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

export function sportsEventResultLabel(event: SportsEvent): string | undefined {
  if (event.homeScore != null || event.awayScore != null) return `${event.homeScore ?? "—"} – ${event.awayScore ?? "—"}`;
  const status = event.status.trim();
  if (status.toLowerCase() === "scheduled" || !status) return undefined;
  return status.toLowerCase() === "tbd" ? "TBD" : status;
}
