import { afterEach, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { SportsFollowingSidebar } from "@/components/SportsFollowingSidebar";
import type { SportsEntity, SportsFeedDefinition, SportsSelection } from "@/lib/sportsFeedClient";

afterEach(cleanup);
const entities: SportsEntity[] = [
  {id:"football",name:"Football",kind:"sport",active:true,competitionIDs:[],aliases:[]},
  {id:"league",name:"NFL",kind:"competition",active:true,competitionIDs:[],aliases:[]},
  {id:"team",name:"Giants",kind:"team",active:true,competitionIDs:["league"],aliases:[]},
  {id:"player",name:"A Player",kind:"athlete",active:true,competitionIDs:[],aliases:[]},
  {id:"driver",name:"A Driver",kind:"driver",active:true,competitionIDs:[],aliases:[]},
  {id:"inactive",name:"Inactive Team",kind:"team",active:false,competitionIDs:[],aliases:[]},
];
const definitions: SportsFeedDefinition[] = entities.map(entity => ({id:`entity:${entity.id}`,title:entity.name,kind:entity.kind,entityIDs:[entity.id],description:"Matching stories"}));
const selection = (reference:string,action:"follow"|"mute"="follow"):SportsSelection => ({reference,action,createdAt:"2026-10-04",updatedAt:"2026-10-04"});
const props = {entities,definitions,selections:[],feedID:"sports"};

it("distinguishes loading, unavailable, and empty interests",()=>{
 const mounted=render(<SportsFollowingSidebar {...props} loading />);
 expect(screen.getByRole("status").textContent).toBe("Loading Your Sports Interests…");
 expect(screen.queryByText(/Follow sports, leagues/)).toBeNull();
 mounted.rerender(<SportsFollowingSidebar {...props} error />);
 expect(screen.getByRole("status").textContent).toContain("could not load");
 expect(screen.queryByText(/Follow sports, leagues/)).toBeNull();
 mounted.rerender(<SportsFollowingSidebar {...props} />);
 expect(screen.getByText(/Follow sports, leagues/)).toBeTruthy();
});

it("groups follows and omits explicit mutes, inactive and unresolved references",()=>{
 render(<SportsFollowingSidebar {...props} selections={[...entities.map(entity=>selection(entity.id)),selection("team","mute"),selection("missing")]} />);
 expect(screen.getByRole("heading",{name:"Sports"})).toBeTruthy();
 expect(screen.getByRole("heading",{name:"Leagues and Competitions"})).toBeTruthy();
 expect(screen.getByRole("heading",{name:"Athletes and Players"})).toBeTruthy();
 expect(screen.getByRole("heading",{name:"Drivers"})).toBeTruthy();
 expect(screen.queryByRole("link",{name:"Giants"})).toBeNull();
 expect(screen.queryByText("Inactive Team")).toBeNull();
 expect(screen.queryByText("missing")).toBeNull();
 expect(screen.getAllByRole("link")).toHaveLength(5);
});

it("keeps a directly followed team visible when its league is muted",()=>{
 render(<SportsFollowingSidebar {...props} selections={[selection("league","mute"),selection("team")]} />);
 expect(screen.getByRole("link",{name:"Giants"})).toBeTruthy();
 expect(screen.queryByRole("link",{name:"NFL"})).toBeNull();
});

it("links matching feeds and changes selection without interfering with modified clicks",()=>{
 const changes:string[]=[];
 render(<SportsFollowingSidebar {...props} feedID="entity:team" selections={[selection("team")]} onFeedChange={id=>changes.push(id)} />);
 const link=screen.getByRole("link",{name:"Giants"});
 expect(link.getAttribute("href")).toBe("/read?feed=sports&sportsFeed=entity%3Ateam");
 expect(link.getAttribute("aria-current")).toBe("page");
 fireEvent.click(link);
 expect(changes).toEqual(["entity:team"]);
 fireEvent.click(link,{ctrlKey:true});
 expect(changes).toEqual(["entity:team"]);
});

it("groups followed para swimming classifications and links their distinct matching feeds",()=>{
 const classes: SportsEntity[] = [
  {id:"s14",name:"Para Swimming S14",kind:"classification",sportID:"swimming",active:true,competitionIDs:["para-swimming"],aliases:["S14"]},
  {id:"sb14",name:"Para Swimming SB14",kind:"classification",sportID:"swimming",active:true,competitionIDs:["para-swimming"],aliases:["SB14"]},
  {id:"sm14",name:"Para Swimming SM14",kind:"classification",sportID:"swimming",active:true,competitionIDs:["para-swimming"],aliases:["SM14"]},
 ];
 const feeds: SportsFeedDefinition[] = classes.map(entity=>({id:`entity:${entity.id}`,title:entity.name,kind:"classification",entityIDs:[entity.id],description:"Matching stories"}));
 const changes:string[]=[];
 const mounted=render(<SportsFollowingSidebar entities={classes} definitions={feeds} selections={classes.map(entity=>selection(entity.id))} feedID="entity:sb14" onFeedChange={id=>changes.push(id)} />);
 expect(screen.getByRole("heading",{name:"Classes and Medley Indices"})).toBeTruthy();
 expect(screen.queryByRole("heading",{name:"Leagues and Competitions"})).toBeNull();
 expect(screen.getAllByRole("link")).toHaveLength(4);
 const selected=screen.getByRole("link",{name:"Para Swimming SB14"});
 expect(selected.getAttribute("aria-current")).toBe("page");
 expect(selected.getAttribute("href")).toBe("/read?feed=sports&sportsFeed=entity%3Asb14");
 const medley=screen.getByRole("link",{name:"Para Swimming SM14"});
 expect(medley.getAttribute("href")).toBe("/read?feed=sports&sportsFeed=entity%3Asm14");
 fireEvent.click(medley);
 expect(changes).toEqual(["entity:sm14"]);
 mounted.rerender(<SportsFollowingSidebar entities={classes} definitions={feeds} selections={[selection("s14"),selection("sb14"),selection("sm14"),selection("sm14","mute")]} feedID="entity:sb14" />);
 expect(screen.queryByRole("link",{name:"Para Swimming SM14"})).toBeNull();
 expect(screen.getByRole("link",{name:"Para Swimming S14"})).toBeTruthy();
 expect(screen.getByRole("link",{name:"Para Swimming SB14"})).toBeTruthy();
});


it("keeps All Sports available during loading, errors, and empty interests",()=>{
 const mounted=render(<SportsFollowingSidebar {...props} loading />);
 expect(screen.getByRole("link",{name:"All Sports"}).getAttribute("href")).toBe("/read?feed=sports");
 expect(screen.getByRole("link",{name:"All Sports"}).getAttribute("aria-current")).toBe("page");
 mounted.rerender(<SportsFollowingSidebar {...props} error feedID="entity:team" />);
 expect(screen.getByRole("link",{name:"All Sports"}).getAttribute("aria-current")).toBeNull();
 mounted.rerender(<SportsFollowingSidebar {...props} />);
 expect(screen.getByRole("link",{name:"All Sports"})).toBeTruthy();
 expect(screen.getAllByRole("link")).toHaveLength(1);
});

it("returns to All Sports on ordinary clicks and preserves native modified navigation",()=>{
 const changes:string[]=[];
 render(<SportsFollowingSidebar {...props} feedID="entity:team" selections={[selection("team")]} onFeedChange={id=>changes.push(id)} />);
 const all=screen.getByRole("link",{name:"All Sports"});
 expect(screen.getAllByRole("link")[0]).toBe(all);
 expect(all.getAttribute("href")).toBe("/read?feed=sports");
 expect(all.getAttribute("aria-current")).toBeNull();
 expect(fireEvent.click(all)).toBe(false);
 expect(changes).toEqual(["sports"]);
 for(const modifier of [{ctrlKey:true},{metaKey:true},{shiftKey:true},{altKey:true}]) {
  expect(fireEvent.click(all,modifier)).toBe(true);
 }
 expect(changes).toEqual(["sports"]);
});

it("fits the remaining viewport and grows or contracts while the feed scrolls",()=>{
 let top=300;
 const rect=spyOn(window.HTMLElement.prototype,"getBoundingClientRect").mockImplementation(function(this:HTMLElement){return {top:this.tagName==="ASIDE"?top:40,bottom:700,left:0,right:300,width:300,height:660,x:0,y:40,toJSON:()=>({})} as DOMRect;});
 try {
  const mounted=render(<div data-sports-scroll><SportsFollowingSidebar {...props} /></div>);
  const panel=screen.getByRole("complementary");const host=panel.parentElement!;
  expect(panel.style.maxHeight).toBe("384px");
  top=60;fireEvent.scroll(host);expect(panel.style.maxHeight).toBe("624px");
  top=400;fireEvent.scroll(host);expect(panel.style.maxHeight).toBe("284px");
  mounted.unmount();
 } finally {rect.mockRestore();}
});

it("contracts when schedules arrive above the sidebar after its initial layout",async()=>{
 let top=60;
 const rect=spyOn(window.HTMLElement.prototype,"getBoundingClientRect").mockImplementation(function(this:HTMLElement){return {top:this.tagName==="ASIDE"?top:40,bottom:700,left:0,right:300,width:300,height:660,x:0,y:40,toJSON:()=>({})} as DOMRect;});
 try {
  const mounted=render(<div data-sports-scroll><SportsFollowingSidebar {...props} /></div>);
  const panel=screen.getByRole("complementary");expect(panel.style.maxHeight).toBe("624px");
  top=300;mounted.rerender(<div data-sports-scroll><p>Schedules Loaded</p><SportsFollowingSidebar {...props} /></div>);
  await waitFor(()=>expect(screen.getByRole("complementary").style.maxHeight).toBe("384px"));mounted.unmount();
 } finally {rect.mockRestore();}
});

it("tracks animated sticky topbar height for sidebar margin and available viewport",async()=>{
 let barHeight=220;
 let resize:ResizeObserverCallback | undefined;
 const observed=new Set<Element>();
 const original=Object.getOwnPropertyDescriptor(globalThis,"ResizeObserver");
 class Observer {
  constructor(callback:ResizeObserverCallback){resize=callback;}
  observe(element:Element){observed.add(element);}
  unobserve(element:Element){observed.delete(element);}
  disconnect(){observed.clear();}
 }
 Object.defineProperty(globalThis,"ResizeObserver",{configurable:true,writable:true,value:Observer});
 const rect=spyOn(window.HTMLElement.prototype,"getBoundingClientRect").mockImplementation(function(this:HTMLElement){const top=this.hasAttribute("data-topic-topbar")?40:this.tagName==="ASIDE"?40+Number.parseFloat(this.style.top||"16"):40;const height=this.hasAttribute("data-topic-topbar")?barHeight:660;return {top,bottom:this.hasAttribute("data-topic-topbar")?top+height:700,left:0,right:300,width:300,height,x:0,y:top,toJSON:()=>({})} as DOMRect;});
 try {
  const view=render(<div data-sports-scroll><section data-topic-topbar>Schedules</section><SportsFollowingSidebar key="following" {...props}/></div>);
  const panel=screen.getByRole("complementary");const bar=screen.getByText("Schedules");
  expect(observed.has(bar)).toBe(true);expect(observed.size).toBe(2);
  expect(panel.style.top).toBe("236px");expect(panel.style.maxHeight).toBe("408px");
  barHeight=140;resize?.([],{} as ResizeObserver);
  await waitFor(()=>expect(panel.style.top).toBe("156px"));expect(panel.style.maxHeight).toBe("488px");
  barHeight=44;resize?.([],{} as ResizeObserver);
  await waitFor(()=>expect(panel.style.top).toBe("60px"));expect(panel.style.maxHeight).toBe("584px");
  barHeight=320;resize?.([],{} as ResizeObserver);
  await waitFor(()=>expect(panel.style.top).toBe("336px"));expect(panel.style.maxHeight).toBe("308px");
  view.rerender(<div data-sports-scroll><SportsFollowingSidebar key="following" {...props}/></div>);
  await waitFor(()=>expect(panel.style.top).toBe("16px"));expect(observed.has(bar)).toBe(false);
  view.unmount();expect(observed.size).toBe(0);
 } finally {rect.mockRestore();if(original)Object.defineProperty(globalThis,"ResizeObserver",original);else Reflect.deleteProperty(globalThis,"ResizeObserver");}
});

it("uses the full viewport for its independent scrolling rail", () => {
 render(<SportsFollowingSidebar {...props} />);
 expect(screen.getByRole("complementary").className).toContain("xl:max-h-[calc(100svh-var(--environment-banner-height,0px)-3rem)]");
});

it("distinguishes failed catalog requests from failed selections and confirmed empty interests", () => {
 const mounted = render(<SportsFollowingSidebar {...props} catalogError />);
 expect(screen.getByText("Sports catalog could not load. Try Refresh.")).toBeTruthy();
 expect(screen.queryByText("Your sports interests could not load. Try Refresh.")).toBeNull();
 expect(screen.queryByText(/Follow sports, leagues, teams/)).toBeNull();
 mounted.rerender(<SportsFollowingSidebar {...props} error />);
 expect(screen.getByText("Your sports interests could not load. Try Refresh.")).toBeTruthy();
 expect(screen.queryByText("Sports catalog could not load. Try Refresh.")).toBeNull();
 expect(screen.queryByText(/Follow sports, leagues, teams/)).toBeNull();
 mounted.rerender(<SportsFollowingSidebar {...props} />);
 expect(screen.queryByRole("status")).toBeNull();
 expect(screen.getByText(/Follow sports, leagues, teams/)).toBeTruthy();
});
