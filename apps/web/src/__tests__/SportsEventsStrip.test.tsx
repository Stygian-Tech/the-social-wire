import { afterEach, beforeAll, afterAll, describe, expect, it, spyOn } from "bun:test";
import { cleanup, render, screen, waitFor, fireEvent, act } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { SportsEventsStrip } from "@/components/SportsEventsStrip";
import * as AppEnvironment from "@/lib/appEnv";
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
const restores:(()=>void)[]=[];
afterEach(()=>{window.localStorage.clear();cleanup();for(const restore of restores.splice(0))restore();});
function mount(hidden:boolean,entities:Sports.SportsEntity[]=[],selections:Sports.SportsSelection[]=[],selectionsLoading=false,viewerDID="public",catalogLoading=false){const client=new QueryClient({defaultOptions:{queries:{retry:false,gcTime:0}}});restores.push(()=>client.clear());return render(<QueryClientProvider client={client}><SportsEventsStrip feedID="sports" hidden={hidden} entities={entities} selections={selections} selectionsLoading={selectionsLoading} viewerDID={viewerDID} catalogLoading={catalogLoading}/></QueryClientProvider>);}
async function openStandings(){await waitFor(()=>expect(screen.getByRole("button",{name:"Standings"})).toBeTruthy());fireEvent.click(screen.getByRole("button",{name:"Standings"}));}
describe("Sports event context",()=>{
 it("labels multiple standings tables with existing catalog competition names",async()=>{const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false,standings:["premier","la-liga"].map(competitionID=>({competitionID,season:"2026",sourceURL:"https://www.thesportsdb.com/",status:"unavailable" as const,degraded:false,rows:[]}))});restores.push(()=>fetch.mockRestore());mount(false,[{id:"premier",name:"Premier League",kind:"competition",competitionIDs:[],aliases:[],active:true},{id:"la-liga",name:"La Liga",kind:"competition",competitionIDs:[],aliases:[],active:true}]);await openStandings();await waitFor(()=>expect(screen.getByText("Premier League · 2026")).toBeTruthy());expect(screen.getByText("La Liga · 2026")).toBeTruthy();expect(screen.queryByText("Standings · 2026")).toBeNull();});
 it("shows standings with source and stale status without requiring fixtures",async()=>{const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false,schedulesStatus:"empty",standings:[{competitionID:"league",season:"2026",sourceURL:"https://www.thesportsdb.com/league/123",status:"available",degraded:true,updatedAt:"2026-10-04T12:00:00Z",rows:[{id:"team",name:"Example United",rank:1,played:10,won:7,drawn:2,lost:1,points:"23",group:"Group A"}]}]});restores.push(()=>fetch.mockRestore());mount(false);expect(screen.queryByRole("table")).toBeNull();await openStandings();await waitFor(()=>expect(screen.getByText("Example United")).toBeTruthy());expect(screen.getByText("Standings · 2026")).toBeTruthy();expect(screen.getByText(/Cached Standings/)).toBeTruthy();expect(screen.getByText("Group A")).toBeTruthy();expect(screen.getByRole("link",{name:"Standings Source"}).getAttribute("href")).toBe("https://www.thesportsdb.com/league/123");expect(screen.getByText("23")).toBeTruthy();});
 it("hides the entire standings component including ranks and team names",async()=>{const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"game",competitionID:"league",entityIDs:[],title:"Upcoming Fixture",startsAt:"2026-10-04T15:00:00Z",status:"Scheduled",updatedAt:"2026-10-04T12:00:00Z"}],degraded:false,standings:[{competitionID:"league",season:"2026",sourceURL:"https://www.thesportsdb.com/",status:"available",degraded:false,rows:[{id:"team",name:"Example United",rank:1,points:"23"}]}]});restores.push(()=>fetch.mockRestore());mount(true);await waitFor(()=>expect(screen.getByText("Upcoming Fixture")).toBeTruthy());expect(screen.queryByText("Example United")).toBeNull();expect(screen.queryByRole("table")).toBeNull();expect(screen.queryByText(/Standings/)).toBeNull();});
 it("keeps schedule context while explaining unavailable standings",async()=>{const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"game",competitionID:"league",entityIDs:[],title:"Upcoming Fixture",startsAt:"2026-10-04T15:00:00Z",status:"Scheduled",updatedAt:"2026-10-04T12:00:00Z"}],degraded:false,schedulesStatus:"available",standings:[{competitionID:"league",season:"2026",sourceURL:"https://www.thesportsdb.com/",status:"unavailable",degraded:false,rows:[]}]});restores.push(()=>fetch.mockRestore());mount(false);await openStandings();await waitFor(()=>expect(screen.getByText("Standings Unavailable")).toBeTruthy());expect(screen.getByText("Upcoming Fixture")).toBeTruthy();expect(screen.queryByRole("table")).toBeNull();});
 it("hides result and status while preserving schedule context",async()=>{const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"game",competitionID:"nba",entityIDs:[],updatedAt:"2026-10-03T12:00:00Z",title:"Team A vs Team B",startsAt:"2026-10-03T11:00:00Z",status:"Finished",homeScore:"100",awayScore:"98"}],updatedAt:"2026-10-03T12:00:00Z",degraded:true});restores.push(()=>fetch.mockRestore());mount(true);await waitFor(()=>expect(screen.getByText("Team A vs Team B")).toBeTruthy());expect(screen.queryByText("100 – 98")).toBeNull();expect(screen.queryByText("Finished")).toBeNull();expect(screen.getByText(/Cached Events/)).toBeTruthy();expect(screen.getByRole("link",{name:"TheSportsDB"}).getAttribute("href")).toBe("https://www.thesportsdb.com/");});
 it("shows recent results when score hiding is disabled",async()=>{const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"game",competitionID:"nba",entityIDs:[],updatedAt:"now",title:"Team A vs Team B",startsAt:"2026-10-03T11:00:00Z",status:"Finished",homeScore:"100",awayScore:"98"}],degraded:false});restores.push(()=>fetch.mockRestore());mount(false);await waitFor(()=>expect(screen.getByText("100 – 98")).toBeTruthy());});
});

describe("Standings places", () => {
 it("renders server zones and linked rules without inventing rank thresholds", async () => {
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false,standings:[{competitionID:"league",season:"2026-2027",sourceURL:"https://www.thesportsdb.com/",status:"available",degraded:false,rows:[{id:"first",name:"Promotion Club",rank:2,points:"20",zone:{kind:"promotion",label:"Automatic Promotion Places",sourceURL:"https://www.efl.com/"}},{id:"last",name:"Relegation Club",rank:22,points:"3",zone:{kind:"relegation",label:"Relegation Places",sourceURL:"https://www.efl.com/"}},{id:"plain",name:"Unmarked Club",rank:1}]}]});restores.push(()=>fetch.mockRestore());
  mount(false);await openStandings();expect(screen.getByText("Automatic Promotion Places")).toBeTruthy();expect(screen.getByText("Relegation Places")).toBeTruthy();expect(screen.getByRole("link",{name:"Automatic Promotion Places Rules"}).getAttribute("href")).toBe("https://www.efl.com/");expect(screen.getByText(/not a secured outcome/)).toBeTruthy();
 });
});

describe("Official brackets and activity", () => {
 it("opens reviewed external brackets in a separate tab with source season", async () => {
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false,bracketSources:[{id:"nba",competitionID:"nba",season:"2025-2026",title:"NBA Playoffs",url:"https://www.nba.com/playoffs/2026/bracket",reviewedAt:"2026-10-04",mode:"external"}]});restores.push(()=>fetch.mockRestore());mount(false);await openStandings();fireEvent.click(screen.getByRole("tab",{name:"Brackets"}));expect(screen.getByRole("tab",{name:"Brackets"}).getAttribute("aria-selected")).toBe("true");expect(screen.getByText(/Season 2025-2026/)).toBeTruthy();expect(screen.getByRole("link",{name:"Open Official Bracket for NBA Playoffs"}).getAttribute("href")).toBe("https://www.nba.com/playoffs/2026/bracket");
 });
 it("exposes data, rules, and reviewed bracket references in Sources", async () => {
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false,standings:[{competitionID:"league",season:"2026",sourceURL:"https://www.thesportsdb.com/league/123",status:"available",degraded:true,updatedAt:"2026-10-04T12:00:00Z",rows:[{id:"a",name:"A",zone:{kind:"promotion",label:"Promotion",sourceURL:"https://www.efl.com/rules"}},{id:"b",name:"B",zone:{kind:"relegation",label:"Relegation",sourceURL:"https://www.efl.com/rules"}}]}],bracketSources:[{id:"nba",competitionID:"nba",season:"2025-2026",title:"NBA Playoffs",url:"https://www.nba.com/playoffs/2026/bracket",reviewedAt:"2026-10-04T12:00:00Z",mode:"external"}]});restores.push(()=>fetch.mockRestore());mount(false);await openStandings();fireEvent.click(screen.getByRole("tab",{name:"Sources"}));expect(screen.getByRole("link",{name:"Competition · 2026 · TheSportsDB"}).getAttribute("href")).toBe("https://www.thesportsdb.com/league/123");expect(screen.getByText(/Cached Data/)).toBeTruthy();expect(screen.getAllByRole("link",{name:"Rules Reference · www.efl.com"})).toHaveLength(1);expect(screen.getByRole("link",{name:"NBA Playoffs · 2025-2026"}).getAttribute("href")).toBe("https://www.nba.com/playoffs/2026/bracket");expect(screen.getByText(/www.nba.com · Reviewed/).querySelector("time")?.getAttribute("datetime")).toBe("2026-10-04T12:00:00Z");expect(screen.getByText(/www.nba.com · Reviewed/).querySelector("time")?.textContent).toBe(new Date("2026-10-04T12:00:00Z").toLocaleDateString(undefined,{timeZone:"UTC"}));expect(screen.getByText(/We do not serve live bracket data/)).toBeTruthy();fireEvent.keyDown(screen.getByRole("tab",{name:"Sources"}),{key:"ArrowRight"});expect(screen.getByRole("tab",{name:"Standings"}).getAttribute("aria-selected")).toBe("true");
 });
 it("shows activity and coverage but suppresses result cues with Hide Scores", async () => {
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"active",title:"Active Game",competitionID:"league",entityIDs:[],startsAt:new Date().toISOString(),updatedAt:new Date().toISOString(),status:"in-progress"}],degraded:false,eventsLimited:true});restores.push(()=>fetch.mockRestore());const view=mount(false);await waitFor(()=>expect(screen.getByText("In Progress")).toBeTruthy());expect(screen.getByText(/Serving Limit Reached/)).toBeTruthy();view.unmount();mount(true);await waitFor(()=>expect(screen.getByText("Active Game")).toBeTruthy());expect(screen.queryByText("In Progress")).toBeNull();
 });
});

describe("Schedule scope", () => {
 const entities: Sports.SportsEntity[] = [
  {id:"soccer",name:"Football",kind:"sport",competitionIDs:[],aliases:[],active:true},
  {id:"league",name:"Premier League",kind:"competition",sportID:"soccer",competitionIDs:[],aliases:[],active:true},
  {id:"team",name:"Example United",kind:"team",sportID:"soccer",competitionIDs:["league"],aliases:[],active:true},
 ];
 const selection = (reference:string,action:"follow"|"mute"="follow"):Sports.SportsSelection => ({reference,action,createdAt:"now",updatedAt:"now"});
 it("labels schedules with the localized sport and competition", async () => {
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"game",title:"Example Fixture",competitionID:"league",entityIDs:["team"],startsAt:"2026-10-04T15:00:00Z",updatedAt:"2026-10-04T12:00:00Z",status:"Scheduled"}],degraded:false});restores.push(()=>fetch.mockRestore());
  mount(false,entities);await waitFor(()=>expect(screen.getByText("Soccer · Premier League")).toBeTruthy());
 });
 it("requests followed teams only and retains the selected feed scope", async () => {
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false});restores.push(()=>fetch.mockRestore());
  mount(false,entities,[selection("soccer"),selection("team")]);
  await act(async () => { fireEvent.change(screen.getByRole("combobox",{name:"Schedule Scope"}),{target:{value:"teams"}}); });
  await waitFor(()=>expect(fetch.mock.calls.some(call=>call[0]==="sports" && JSON.stringify(call[2])==='["team"]')).toBe(true));
  expect(window.localStorage.getItem("the-social-wire.sports-schedule-scope.v1:public")).toBe("teams");
 });
 it("never backfills broad sports when no team is followed or a team is explicitly muted", async () => {
  window.localStorage.setItem("the-social-wire.sports-schedule-scope.v1:public","teams");
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false});restores.push(()=>fetch.mockRestore());
  mount(false,entities,[selection("soccer"),selection("team"),selection("team","mute")]);
  expect(screen.getByText("Follow a team to see its schedule here.")).toBeTruthy();expect(fetch).not.toHaveBeenCalled();
 });
 it("waits for followed interests without showing empty-follow guidance or requesting broad data", () => {
  window.localStorage.setItem("the-social-wire.sports-schedule-scope.v1:public","teams");
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false});restores.push(()=>fetch.mockRestore());
  mount(false,entities,[],true);
  expect(screen.getByText("Loading Schedules…")).toBeTruthy();expect(screen.queryByText("Follow a team to see its schedule here.")).toBeNull();expect(fetch).not.toHaveBeenCalled();
 });

});

describe("Interest schedule scope", () => {
 it("uses Your Sports once interests exist and sends the follows with timezone", async () => {
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false});restores.push(()=>fetch.mockRestore());
  mount(false,[{id:"swimming",name:"Swimming",kind:"sport",competitionIDs:[],aliases:[],active:true}],[{reference:"swimming",action:"follow",createdAt:"now",updatedAt:"now"}]);
  expect(screen.getByRole("option",{name:"Your Sports"})).toBeTruthy();expect(screen.queryByRole("option",{name:"All Sports"})).toBeNull();
  await waitFor(()=>expect(fetch.mock.calls[0]?.[3]?.preferredIDs).toEqual(["swimming"]));
 });
 it("never requests generic schedules while interests are reconciling", () => {
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false});restores.push(()=>fetch.mockRestore());mount(false,[],[],true);
  expect(screen.getByText("Loading Schedules…")).toBeTruthy();expect(fetch).not.toHaveBeenCalled();
 });
});

 describe("Persisted category scopes", () => {
 const entities:Sports.SportsEntity[]=[{id:"sport",name:"Swimming",kind:"sport",competitionIDs:[],aliases:[],active:true},{id:"league",name:"World Championships",kind:"competition",sportID:"sport",competitionIDs:[],aliases:[],active:true},{id:"team",name:"National Team",kind:"team",sportID:"sport",competitionIDs:["league"],aliases:[],active:true}];
 const selections=entities.map(entity=>({reference:entity.id,action:"follow" as const,createdAt:"now",updatedAt:"now"}));
 it.each([['sports','sport'],['leagues','league']] as const)("persists %s and restores only its followed category", async (scope,id) => {
 const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false});restores.push(()=>fetch.mockRestore());const view=mount(false,entities,selections);fireEvent.change(screen.getByRole("combobox",{name:"Schedule Scope"}),{target:{value:scope}});await waitFor(()=>expect(fetch.mock.calls.some(call=>JSON.stringify(call[3]?.preferredIDs)===JSON.stringify([id]))).toBe(true));expect(window.localStorage.getItem("the-social-wire.sports-schedule-scope.v1:public")).toBe(scope);view.unmount();fetch.mockClear();mount(false,entities,selections);await waitFor(()=>expect(fetch.mock.calls[0]?.[3]?.preferredIDs).toEqual([id]));expect((screen.getByRole("combobox",{name:"Schedule Scope"}) as HTMLSelectElement).value).toBe(scope);
 });
 it("does not request generic fixtures when the persisted category has no follows", () => {window.localStorage.setItem("the-social-wire.sports-schedule-scope.v1:public","leagues");const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false});restores.push(()=>fetch.mockRestore());mount(false,entities,[]);expect(fetch).not.toHaveBeenCalled();expect(screen.getByText(/Follow leagues or competitions/)).toBeTruthy();});
 it("does not restore another viewer's scope", () => {window.localStorage.setItem("the-social-wire.sports-schedule-scope.v1:did:plc:other","teams");const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false});restores.push(()=>fetch.mockRestore());mount(false,entities,selections);expect((screen.getByRole("combobox",{name:"Schedule Scope"}) as HTMLSelectElement).value).toBe("all");});
 });

it("preserves explicit mutes, active catalog filtering, and category scope requests with indexed lookups",async()=>{
 const entities:Sports.SportsEntity[]=[{id:"sport",name:"Swimming",kind:"sport",competitionIDs:[],aliases:[],active:true},{id:"league",name:"World Championships",kind:"competition",sportID:"sport",competitionIDs:[],aliases:[],active:true},{id:"team",name:"National Team",kind:"team",sportID:"sport",competitionIDs:["league"],aliases:[],active:true},{id:"inactive",name:"Inactive Sport",kind:"sport",competitionIDs:[],aliases:[],active:false}];
 const follow=(reference:string,action:"follow"|"mute"="follow"):Sports.SportsSelection=>({reference,action,createdAt:"now",updatedAt:"now"});
 const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false});restores.push(()=>fetch.mockRestore());
 mount(false,entities,[follow("sport"),follow("team"),follow("team"),follow("league"),follow("league","mute"),follow("inactive"),follow("missing")]);
 await waitFor(()=>expect(fetch.mock.calls[0]?.[3]?.preferredIDs).toEqual(["sport","team"]));
 fireEvent.change(screen.getByRole("combobox",{name:"Schedule Scope"}),{target:{value:"teams"}});
 await waitFor(()=>expect(fetch.mock.calls.some(call=>JSON.stringify(call[3]?.preferredIDs)==='["team"]'&&JSON.stringify(call[2])==='["team"]')).toBe(true));
 fireEvent.change(screen.getByRole("combobox",{name:"Schedule Scope"}),{target:{value:"sports"}});
 await waitFor(()=>expect(fetch.mock.calls.some(call=>JSON.stringify(call[3]?.preferredIDs)==='["sport"]')).toBe(true));
 const requestCount=fetch.mock.calls.length;
 fireEvent.change(screen.getByRole("combobox",{name:"Schedule Scope"}),{target:{value:"leagues"}});
 expect(screen.getByText(/Follow leagues or competitions/)).toBeTruthy();
 expect(fetch.mock.calls.length).toBe(requestCount);
});

it("contains long competition and fixture labels within flexible-width equal-height schedule cards while preserving short names",async()=>{
 const entities:Sports.SportsEntity[]=[{id:"football",name:"American Football",kind:"sport",competitionIDs:[],aliases:[],active:true},{id:"ncaa",name:"NCAA Division I Football",kind:"competition",sportID:"football",competitionIDs:[],aliases:[],active:true},{id:"motorsport",name:"Motorsport",kind:"sport",competitionIDs:[],aliases:[],active:true},{id:"f1",name:"Formula 1",kind:"competition",sportID:"motorsport",competitionIDs:[],aliases:[],active:true}];
 const title="A Very Long University Football Team vs Another Long University Football Team";
 const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"ncaa-game",title,competitionID:"ncaa",entityIDs:[],startsAt:"2099-10-04T15:00:00Z",updatedAt:"2026-10-04T12:00:00Z",status:"scheduled"},{id:"race",title:"Grand Prix",competitionID:"f1",entityIDs:[],startsAt:"2099-10-04T15:00:00Z",updatedAt:"2026-10-04T12:00:00Z",status:"scheduled"}],degraded:false});restores.push(()=>fetch.mockRestore());
 mount(false,entities);
 await waitFor(()=>expect(screen.getByText(title)).toBeTruthy());
 const card=screen.getByText(title).closest("article")!;
 expect(card.classList.contains("w-max")).toBe(true);
 expect(card.classList.contains("min-w-52")).toBe(true);
 expect(card.classList.contains("max-w-[min(24rem,calc(100vw-2rem))]")).toBe(true);
 expect(card.parentElement?.classList.contains("items-stretch")).toBe(true);
 expect(card.classList.contains("shrink-0")).toBe(true);
 expect(screen.getByText(title).classList.contains("min-w-0")).toBe(true);
 expect(card.classList.contains("[overflow-wrap:anywhere]")).toBe(true);
 expect(screen.getByText(/NCAA Division I Football/).textContent).toBe("Football · NCAA Division I Football");
 expect(screen.getByText(/Motorsport/).textContent).toBe("Motorsport · Formula\u00a01");
 expect(card.querySelector("time")?.classList.contains("block")).toBe(true);
});


describe("Schedule presentation", () => {
 const fixture:Sports.SportsEvents = {events:[{id:"fixture",competitionID:"league",entityIDs:[],title:"Upcoming Fixture",startsAt:"2099-10-04T15:00:00Z",status:"scheduled",updatedAt:"2026-10-04T12:00:00Z"}],updatedAt:"2026-10-04T12:00:00Z",degraded:false,standings:[{competitionID:"league",season:"2026",sourceURL:"https://www.thesportsdb.com/",status:"unavailable",degraded:false,rows:[]}]};
 it("collapses fixtures while keeping scope and standings usable, then restores the browser choice", async () => {
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue(fixture);restores.push(()=>fetch.mockRestore());
  const view=mount(false);
  await waitFor(()=>expect(screen.getByText("Upcoming Fixture")).toBeTruthy());
  const button=screen.getByRole("button",{name:"Collapse Schedules"});
  const section=screen.getByRole("region",{name:"Sports Events"});
  expect(section.classList.contains("sticky")).toBe(true);expect(section.classList.contains("top-0")).toBe(true);expect(section.classList.contains("bg-background")).toBe(true);
  const body=document.getElementById(button.getAttribute("aria-controls")!)!;
  expect((body.querySelector("[data-schedule-body]") as HTMLElement)?.style.minHeight).toBe("");
  fireEvent.click(button);
  expect(screen.getByRole("button",{name:"Expand Schedules"}).getAttribute("aria-expanded")).toBe("false");
  expect(body.isConnected).toBe(true);expect(body.getAttribute("aria-hidden")).toBe("true");expect(body.hasAttribute("inert")).toBe(true);
  expect(screen.getByText("Upcoming Fixture").closest("[aria-hidden=true]")).toBeTruthy();
  expect(screen.getByRole("combobox",{name:"Schedule Scope"})).toBeTruthy();expect(screen.getByRole("button",{name:"Standings"})).toBeTruthy();
  expect(window.localStorage.getItem("the-social-wire.sports-schedules-expanded.v1:public")).toBe("false");
  view.unmount();mount(false);
  expect(screen.getByRole("button",{name:"Expand Schedules"})).toBeTruthy();
  fireEvent.click(screen.getByRole("button",{name:"Expand Schedules"}));
  await waitFor(()=>expect(screen.getByText("Upcoming Fixture")).toBeTruthy());
  expect(window.localStorage.getItem("the-social-wire.sports-schedules-expanded.v1:public")).toBe("true");
 });
 it("isolates the collapsed choice by viewer", () => {
  window.localStorage.setItem("the-social-wire.sports-schedules-expanded.v1:did:plc:other","false");
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue(fixture);restores.push(()=>fetch.mockRestore());mount(false);
  expect(screen.getByRole("button",{name:"Collapse Schedules"})).toBeTruthy();
 });
 it("keeps toggling available when browser storage writes fail", () => {
  const viewer="did:plc:storage-unavailable";
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue(fixture);restores.push(()=>fetch.mockRestore());
  const storage=spyOn(Object.getPrototypeOf(window.localStorage),"setItem").mockImplementation(()=>{throw new Error("quota");});restores.push(()=>storage.mockRestore());
  mount(false,[],[],false,viewer);
  fireEvent.click(screen.getByRole("button",{name:"Collapse Schedules"}));expect(screen.getByRole("button",{name:"Expand Schedules"})).toBeTruthy();
  fireEvent.click(screen.getByRole("button",{name:"Expand Schedules"}));expect(screen.getByRole("button",{name:"Collapse Schedules"})).toBeTruthy();
 });
 it("reserves expanded loading space without requesting schedules before the catalog arrives", () => {
  const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue(fixture);restores.push(()=>fetch.mockRestore());mount(false,[],[],false,"public",true);
  expect(fetch).not.toHaveBeenCalled();expect(screen.getByRole("status").textContent).toBe("Loading Schedules…");
  const body=document.getElementById(screen.getByRole("button",{name:"Collapse Schedules"}).getAttribute("aria-controls")!)!;
  expect((body.querySelector("[data-schedule-body]") as HTMLElement)?.style.minHeight).toBe("var(--sports-body-min-height,176px)");expect(body.querySelectorAll(".bg-muted\\/40")).toHaveLength(3);
  fireEvent.click(screen.getByRole("button",{name:"Collapse Schedules"}));expect(screen.queryByRole("status")).toBeNull();expect(body.isConnected).toBe(true);expect(body.getAttribute("aria-hidden")).toBe("true");expect(body.hasAttribute("inert")).toBe(true);
 });
});


it("smoothly condenses the pane's sticky cards to verified abbreviations with readable fallback",async()=>{
 const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"game",competitionID:"nfl",entityIDs:[],title:"Philadelphia Eagles vs Los Angeles Rams",homeName:"Philadelphia Eagles",awayName:"Los Angeles Rams",homeAbbreviation:"PHI",awayAbbreviation:"LAR",startsAt:"2099-10-04T15:00:00Z",status:"scheduled",updatedAt:"now"},{id:"other",competitionID:"nfl",entityIDs:[],title:"Long Home Team vs Long Away Team",homeName:"Long Home Team",awayName:"Long Away Team",startsAt:"2099-10-04T15:00:00Z",status:"scheduled",updatedAt:"now"}],degraded:false});restores.push(()=>fetch.mockRestore());
 const client=new QueryClient({defaultOptions:{queries:{retry:false,gcTime:0}}});restores.push(()=>client.clear());
 render(<QueryClientProvider client={client}><div data-sports-scroll data-testid="scroll-pane"><SportsEventsStrip feedID="sports" hidden={false} /></div></QueryClientProvider>);
 await waitFor(()=>expect(screen.getByText("Philadelphia Eagles vs Los Angeles Rams")).toBeTruthy());
 const fullLayer=screen.getByText("Philadelphia Eagles vs Los Angeles Rams").closest("[data-schedule-label]")!;
 const compactLayer=screen.getByText("PHI vs LAR").closest("[data-schedule-label]")!;
 expect(fullLayer.getAttribute("aria-hidden")).toBe("false");expect(compactLayer.getAttribute("aria-hidden")).toBe("true");
 expect(fullLayer.classList.contains("col-start-1")).toBe(true);expect(compactLayer.classList.contains("col-start-1")).toBe(true);
 const host=screen.getByTestId("scroll-pane");host.scrollTop=100;fireEvent.scroll(host);
 await waitFor(()=>expect(screen.getByText("PHI vs LAR").closest("[data-schedule-label]")?.getAttribute("aria-hidden")).toBe("false"));
 expect(screen.getByText("PHI vs LAR").closest("p")?.getAttribute("aria-label")).toBe("Philadelphia Eagles vs Los Angeles Rams");
 expect(screen.getByText("Long Home Team vs Long Away Team")).toBeTruthy();
 expect(fullLayer.isConnected).toBe(true);expect(fullLayer.getAttribute("aria-hidden")).toBe("true");
 expect((fullLayer as HTMLElement).style.gridTemplateRows).toBe("var(--sports-full-row,1fr)");expect((compactLayer as HTMLElement).style.gridTemplateRows).toBe("var(--sports-compact-row,0fr)");
 expect(fullLayer.className).not.toContain("duration-");
 expect(compactLayer.className).not.toContain("transition-");
 const section=screen.getByRole("region",{name:"Sports Events"});expect(section.getAttribute("data-compact")).toBe("true");
 const card=screen.getByText("PHI vs LAR").closest("article")!;expect((card as HTMLElement).style.paddingBlock).toBe("var(--sports-card-padding,8px)");
 expect(screen.queryByText(/^scheduled$/i)).toBeNull();
 fireEvent.click(screen.getByRole("button",{name:"Collapse Schedules"}));expect(screen.getByText("PHI vs LAR").closest("[inert]")).toBeTruthy();
 fireEvent.click(screen.getByRole("button",{name:"Expand Schedules"}));expect(screen.getByText("PHI vs LAR")).toBeTruthy();
 host.scrollTop=0;fireEvent.scroll(host);await waitFor(()=>expect(section.getAttribute("data-compact")).toBe("false"));
 expect(screen.getByText("Philadelphia Eagles vs Los Angeles Rams")).toBeTruthy();expect(screen.getByText("PHI vs LAR").closest("[data-schedule-label]")?.getAttribute("aria-hidden")).toBe("true");
});

it.each([false,true])("reveals the full compact card on hover or keyboard focus outside the rail, respecting Hide Scores=%s",async(hidden)=>{
 const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"game",competitionID:"nfl",entityIDs:[],title:"Philadelphia Eagles vs Los Angeles Rams",homeName:"Philadelphia Eagles",awayName:"Los Angeles Rams",homeAbbreviation:"PHI",awayAbbreviation:"LAR",homeScore:"24",awayScore:"20",startsAt:"2099-10-04T15:00:00Z",status:"finished",updatedAt:"now"}],degraded:false});restores.push(()=>fetch.mockRestore());
 const client=new QueryClient({defaultOptions:{queries:{retry:false,gcTime:0}}});restores.push(()=>client.clear());
 render(<QueryClientProvider client={client}><div data-sports-scroll data-testid="scroll-pane"><SportsEventsStrip feedID="sports" hidden={hidden}/></div></QueryClientProvider>);
 await waitFor(()=>expect(screen.getByText("Philadelphia Eagles vs Los Angeles Rams")).toBeTruthy());
 const host=screen.getByTestId("scroll-pane");host.scrollTop=100;fireEvent.scroll(host);await waitFor(()=>expect(screen.getByText(/^PHI vs LAR/).closest("[data-schedule-label]")?.getAttribute("aria-hidden")).toBe("false"));
 const card=screen.getByText(/^PHI vs LAR/).closest("article")!;expect(card.getAttribute("tabindex")).toBe("0");
 if (hidden) { fireEvent.keyDown(document,{key:"Tab"});await act(()=>card.focus()); } else { fireEvent.mouseEnter(card);fireEvent.mouseMove(card); }
 await waitFor(()=>expect(screen.getByRole("tooltip")).toBeTruthy());
 const preview=screen.getByRole("tooltip");expect(preview.textContent).toContain("Philadelphia Eagles vs Los Angeles Rams");expect(preview.textContent?.includes("24 – 20")).toBe(!hidden);
 expect(screen.getByRole("region",{name:"Sports Events"}).contains(preview)).toBe(false);
 expect(preview.classList.contains("motion-reduce:animate-none")).toBe(true);
 fireEvent.keyDown(card,{key:"Escape"});expect(preview.isConnected).toBe(true);expect(preview.getAttribute("aria-hidden")).toBe("true");await waitFor(()=>expect(screen.queryByRole("tooltip")).toBeNull());
 await waitFor(()=>expect(preview.isConnected).toBe(false));
 expect(screen.getByText(/^PHI vs LAR/)).toBeTruthy();
});


it.each([true,false])("limits the schedule footer diagnostics to Development=%s",async(development)=>{
 const environment=spyOn(AppEnvironment,"isDevDebugUiEnabled").mockReturnValue(development);restores.push(()=>environment.mockRestore());
 const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"fixture",title:"Example Fixture",competitionID:"league",entityIDs:[],startsAt:"2099-10-04T15:00:00Z",status:"scheduled",updatedAt:"2026-10-04T12:00:00Z"}],updatedAt:"2026-10-04T12:00:00Z",degraded:true,eventsLimited:true});restores.push(()=>fetch.mockRestore());mount(false);
 await waitFor(()=>expect(screen.getByText("Example Fixture")).toBeTruthy());
 const attribution=screen.getByRole("link",{name:"TheSportsDB"});expect(attribution.getAttribute("href")).toBe("https://www.thesportsdb.com/");
 if(development){expect(screen.getByText(/1 Fixtures/)).toBeTruthy();expect(screen.getByText(/Serving Limit Reached/)).toBeTruthy();expect(screen.getByText(/Cached Events/)).toBeTruthy();}
 else {expect(screen.queryByText(/1 Fixtures/)).toBeNull();expect(screen.queryByText(/Serving Limit Reached/)).toBeNull();expect(screen.queryByText(/Cached Events/)).toBeNull();const footer=attribution.closest("p")!;expect(footer.textContent).toContain("Coverage Varies By Competition.");expect(footer.classList.contains("whitespace-nowrap")).toBe(true);expect(footer.classList.contains("min-w-0")).toBe(true);expect(attribution.classList.contains("shrink-0")).toBe(true);expect(footer.querySelector(".truncate")?.getAttribute("title")).toBe("Coverage Varies By Competition.");expect(footer.querySelector(".sr-only")?.textContent).toContain("Cached event data.");expect(footer.querySelector(".sr-only")?.textContent).toContain("Last updated");}
});

it.each([
 {status:"finished",homeScore:"24",awayScore:"20",hidden:false,score:"24 – 20",description:"Final Score"},
 {status:"in-progress",homeScore:"0",awayScore:"0",hidden:false,score:"0 – 0",description:"Current Score"},
 {status:"scheduled",homeScore:"0",awayScore:"0",hidden:false,score:undefined,description:undefined},
 {status:"finished",homeScore:"24",awayScore:"20",hidden:true,score:undefined,description:undefined},
])("keeps confirmed current/final scores inline in compact cards, respecting hidden and unstarted fixtures: %j",async fixture=>{
 const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"game",competitionID:"nfl",entityIDs:[],title:"Philadelphia Eagles vs Los Angeles Rams",homeName:"Philadelphia Eagles",awayName:"Los Angeles Rams",homeAbbreviation:"PHI",awayAbbreviation:"LAR",homeScore:fixture.homeScore,awayScore:fixture.awayScore,startsAt:"2099-10-04T15:00:00Z",status:fixture.status,updatedAt:"now"}],degraded:false});restores.push(()=>fetch.mockRestore());
 const client=new QueryClient({defaultOptions:{queries:{retry:false,gcTime:0}}});restores.push(()=>client.clear());
 render(<QueryClientProvider client={client}><div data-sports-scroll data-testid="scroll-pane"><SportsEventsStrip feedID="sports" hidden={fixture.hidden}/></div></QueryClientProvider>);
 await waitFor(()=>expect(screen.getByText("Philadelphia Eagles vs Los Angeles Rams")).toBeTruthy());
 const fullCard=screen.getByText("Philadelphia Eagles vs Los Angeles Rams").closest("article")!;
 const widthClasses=fullCard.className;
 const host=screen.getByTestId("scroll-pane");host.scrollTop=100;fireEvent.scroll(host);
 await waitFor(()=>expect(screen.getByRole("region",{name:"Sports Events"}).getAttribute("data-compact")).toBe("true"));
 const label=fullCard.querySelector('[data-schedule-label="compact"]')!;
 expect(label.textContent).toBe(`PHI vs LAR${fixture.score ? ` · ${fixture.score}` : ""}`);
 expect(label.getAttribute("aria-hidden")).toBe("false");
 const accessible=fullCard.getAttribute("aria-label");
 if(fixture.description)expect(accessible).toContain(fixture.description);else expect(accessible).toBe("Philadelphia Eagles vs Los Angeles Rams");
 expect(fullCard.classList.contains("w-max")).toBe(true);expect(widthClasses).toContain("w-max");
 expect(fullCard.querySelectorAll("time")).toHaveLength(1);
 if(fixture.hidden){expect(fullCard.textContent).not.toContain("24 – 20");expect(fullCard.textContent).not.toContain("In Progress");expect(fullCard.className).not.toContain("border-red");}
});


it("My Teams selects relevant leagues while the standings dialog retains every opponent", async () => {
 const team:Sports.SportsEntity={id:"team-a",name:"Followed Team",kind:"team",competitionIDs:["league"],aliases:[],active:true};
 const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[],degraded:false,standings:[{competitionID:"league",season:"2026",sourceURL:"https://www.thesportsdb.com/",status:"available",degraded:false,rows:[{id:"rival",entityID:"team-b",name:"Rival Team",rank:1},{id:"followed",entityID:"team-a",name:"Followed Team",rank:8},{id:"unknown",name:"Unmapped Team",rank:9}]}]});
 restores.push(()=>fetch.mockRestore());
 mount(false,[team],[{reference:team.id,action:"follow",createdAt:"now",updatedAt:"now"}]);
 fireEvent.change(screen.getByRole("combobox",{name:"Schedule Scope"}),{target:{value:"teams"}});
 await waitFor(()=>expect(fetch.mock.calls.at(-1)?.[2]).toEqual(["team-a"]));
 await openStandings();
 expect(screen.getByText(/Full league tables for competitions with your followed teams/)).toBeTruthy();
 for(const name of ["Rival Team","Followed Team","Unmapped Team"]) expect(screen.getByRole("rowheader",{name})).toBeTruthy();
});

it("opens compact previews after rest, keeps click focus visible, and reopens after an interrupted exit", async () => {
 const fetch=spyOn(Sports,"getSportsEvents").mockResolvedValue({events:[{id:"repeat",competitionID:"league",entityIDs:[],title:"Home Team vs Away Team",homeName:"Home Team",awayName:"Away Team",homeAbbreviation:"HOME",awayAbbreviation:"AWAY",startsAt:"2099-10-04T15:00:00Z",status:"scheduled",updatedAt:"now"}],degraded:false});restores.push(()=>fetch.mockRestore());
 const client=new QueryClient({defaultOptions:{queries:{retry:false,gcTime:0}}});restores.push(()=>client.clear());
 render(<QueryClientProvider client={client}><div data-sports-scroll data-testid="repeat-scroll"><SportsEventsStrip feedID="sports" hidden={false}/></div></QueryClientProvider>);
 await waitFor(()=>expect(screen.getByText("Home Team vs Away Team")).toBeTruthy());
 const host=screen.getByTestId("repeat-scroll");host.scrollTop=100;fireEvent.scroll(host);
 await waitFor(()=>expect(screen.getByRole("region",{name:"Sports Events"}).getAttribute("data-compact")).toBe("true"));
 const card=screen.getByText("HOME vs AWAY").closest("article")!;
 fireEvent.mouseEnter(card);fireEvent.mouseMove(card);
 await waitFor(()=>expect(screen.getByRole("tooltip")).toBeTruthy());
 fireEvent.pointerDown(card,{pointerType:"mouse"});fireEvent.click(card);
 expect(screen.getByRole("tooltip")).toBeTruthy();
 fireEvent.keyDown(card,{key:"Escape"});
 expect(screen.queryByRole("tooltip")).toBeNull();
 fireEvent.mouseLeave(card);fireEvent.mouseEnter(card);fireEvent.mouseMove(card);
 await waitFor(()=>expect(screen.getByRole("tooltip")).toBeTruthy());
 expect(screen.getByRole("tooltip").textContent).toContain("Home Team vs Away Team");
 expect(host.scrollTop).toBe(100);
});
