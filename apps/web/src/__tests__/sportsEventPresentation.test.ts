import { describe, expect, it } from "bun:test";
import { sportsEventHighlight, sportsEventStartLabel, sportsEventResultLabel } from "@/lib/sportsEventPresentation";
import type { SportsEvent } from "@/lib/sportsFeedClient";
const now = Date.parse("2026-10-04T12:00:00Z");
const event = (status: string, startsAt: string): SportsEvent => ({ id:"game", competitionID:"league", entityIDs:[], title:"Fixture", status, startsAt, updatedAt:"2026-10-04T12:00:00Z" });
describe("Sports event emphasis", () => {
 it("marks confirmed active games even after a long fixture", () => expect(sportsEventHighlight(event("in-progress", "2026-10-01T12:00:00Z"), now)).toBe("In Progress"));
 it("marks today's finished fixtures without claiming their finish timestamp", () => expect(sportsEventHighlight(event("finished", "2026-10-04T01:00:00Z"), now)).toBe("Recent Result"));
 it("does not use refresh time to highlight old results", () => expect(sportsEventHighlight(event("finished", "2026-10-02T12:00:00Z"), now)).toBeUndefined());
 it("does not highlight future finished, postponed, or scheduled fixtures", () => { for (const status of ["finished", "postponed", "scheduled"]) expect(sportsEventHighlight(event(status, "2026-10-05T12:00:00Z"), now)).toBeUndefined(); });
 it("keeps late results for the viewer's game day across UTC midnight", () => expect(sportsEventHighlight(event("finished", "2026-10-04T03:00:00Z"), Date.parse("2026-10-04T05:00:00Z"), "America/Los_Angeles")).toBe("Recent Result"));
 it("expires the highlight at local midnight", () => expect(sportsEventHighlight(event("finished", "2026-10-04T03:00:00Z"), Date.parse("2026-10-04T08:00:00Z"), "America/Los_Angeles")).toBeUndefined());
});


describe("Sports schedule labels", () => {
 it("omits scheduled labels while keeping final scores and consequential statuses", () => {
  expect(sportsEventResultLabel(event("Scheduled", "2026-10-04T00:00:00Z"))).toBeUndefined();
  expect(sportsEventResultLabel(event("postponed", "2026-10-04T00:00:00Z"))).toBe("postponed");
  expect(sportsEventResultLabel({...event("finished", "2026-10-04T00:00:00Z"),homeScore:"24",awayScore:"20"})).toBe("24 – 20");
 });
 it("uses TBD only for explicit missing time or invalid dates, preserving real midnight", () => {
  const known=event("scheduled", "2026-10-04T00:00:00Z");
  expect(sportsEventStartLabel(known)).not.toContain("TBD");
  expect(sportsEventStartLabel({...known,startTimeKnown:true})).not.toContain("TBD");
  expect(sportsEventStartLabel({...known,startTimeKnown:false})).toContain("TBD");
  expect(sportsEventStartLabel(event("scheduled", "invalid"))).toBe("TBD");
 });
});
