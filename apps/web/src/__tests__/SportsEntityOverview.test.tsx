import { afterEach, beforeAll, afterAll, describe, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { SportsEntityOverview } from "@/components/SportsEntityOverview";
import * as Sports from "@/lib/sportsFeedClient";
const globalKeys = ["DOMRect", "Element", "HTMLElement", "Node", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame"] as const;
const originals = new Map(globalKeys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
beforeAll(() => {
  const values = { DOMRect: window.DOMRect, Element: window.Element, HTMLElement: window.HTMLElement, Node: window.Node, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: (handle: ReturnType<typeof setTimeout>) => clearTimeout(handle) };
  for (const key of globalKeys) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value: values[key] });
});
afterAll(() => {
  for (const key of globalKeys) {
    const original = originals.get(key);
    if (original) Object.defineProperty(globalThis, key, original);
    else Reflect.deleteProperty(globalThis, key);
  }
});

const entity: Sports.SportsEntity = { id: "team", name: "Example United", kind: "team", competitionIDs: ["league"], aliases: [], active: true };
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).forEach(restore => restore()); });
function mount(hidden = false, eventsEnabled = true, viewerDID = "public") {
 const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } }); restores.push(() => client.clear());
 return render(<QueryClientProvider client={client}><SportsEntityOverview feedID="entity:team" entity={entity} entities={[entity]} hidden={hidden} eventsEnabled={eventsEnabled} viewerDID={viewerDID} /></QueryClientProvider>);
}
function event(id: string, status: string, startsAt: string): Sports.SportsEvent { return { id, title: `${id} Fixture`, status, startsAt, updatedAt: startsAt, competitionID: "league", entityIDs: ["team"], homeScore: "2", awayScore: "1" }; }
describe("Sports entity overview", () => {
 it("requests the exact entity feed independently of follows", async () => {
 const fetch = spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false}); restores.push(()=>fetch.mockRestore()); mount(); await waitFor(()=>expect(fetch.mock.calls.length).toBe(1)); expect(fetch.mock.calls[0][0]).toBe("entity:team"); expect(fetch.mock.calls[0][2]).toBeUndefined(); expect(fetch.mock.calls[0][3]?.preferredIDs).toEqual([]); await waitFor(()=>expect(screen.getByText(/No upcoming fixtures/)).toBeTruthy());
 });
 it("prioritizes current events, bounds fixtures, and preserves official team ranks", async () => {
 const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[event("Ended","finished","2020-10-04T12:00:00Z"),event("Current","in-progress","2026-10-04T12:00:00Z"),...Array.from({length:10},(_,index)=>event(`Future ${index}`,"scheduled",`2099-10-${String(index+1).padStart(2,"0")}T12:00:00Z`))],degraded:false,standings:[{competitionID:"league",season:"2026",sourceURL:"https://www.thesportsdb.com/",status:"available",degraded:false,rows:[{id:"other",entityID:"other",name:"Another Team",rank:1},{id:"team",entityID:"team",name:"Example United",rank:8,points:"14"}]}]}); restores.push(()=>fetch.mockRestore()); mount(); await waitFor(()=>expect(screen.getByText("Current Fixture")).toBeTruthy()); expect(screen.queryByText("Ended Fixture")).toBeNull(); expect(screen.getByText("2 – 1")).toBeTruthy(); expect(screen.getByText("Future 5 Fixture")).toBeTruthy(); expect(screen.queryByText("Future 6 Fixture")).toBeNull(); fireEvent.click(screen.getByRole("button",{name:"Show More Fixtures"})); expect(screen.getByText("Future 9 Fixture")).toBeTruthy(); expect(screen.queryByRole("button",{name:"Show More Fixtures"})).toBeNull(); expect(screen.getByText("8. Example United")).toBeTruthy(); expect(screen.queryByText("Another Team")).toBeNull(); fireEvent.click(screen.getByRole("button",{name:"Standings"})); await waitFor(()=>expect(screen.getByText("Another Team")).toBeTruthy()); expect(screen.getByRole("rowheader",{name:"Example United"})).toBeTruthy();
 });
 it("suppresses result and standings cues when hidden", async () => {
 const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[event("Current","in-progress","2026-10-04T12:00:00Z"),event("Future","scheduled","2099-10-04T12:00:00Z")],degraded:false}); restores.push(()=>fetch.mockRestore()); mount(true); await waitFor(()=>expect(screen.getByText("Future Fixture")).toBeTruthy()); expect(screen.queryByText("Current Fixture")).toBeNull(); expect(screen.queryByText("2 – 1")).toBeNull(); expect(screen.queryByText("In Progress")).toBeNull(); expect(screen.queryByText("Standings Snapshot")).toBeNull();
 });
 it("keeps news available without provider access", () => { const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false}); restores.push(()=>fetch.mockRestore()); mount(false,false); expect(fetch).not.toHaveBeenCalled(); expect(screen.getByText(/Schedules and standings are not enabled/)).toBeTruthy(); });
 it("shows final results with cached source freshness", async () => { const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[event("Ended","finished","2020-10-04T12:00:00Z")],degraded:true,updatedAt:"2026-10-04T12:00:00Z"}); restores.push(()=>fetch.mockRestore()); mount(false,true,"did:plc:viewer"); await waitFor(()=>expect(screen.getByText("Ended Fixture")).toBeTruthy()); expect(screen.getByText("Final")).toBeTruthy(); expect(screen.getByText(/Cached Event Coverage/)).toBeTruthy(); expect(screen.getByRole("link",{name:"TheSportsDB"}).getAttribute("href")).toBe("https://www.thesportsdb.com/"); });
});
