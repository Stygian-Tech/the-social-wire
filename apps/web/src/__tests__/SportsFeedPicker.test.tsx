import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as PickerTree from "@/lib/sportsFeedPickerTree";
import { SportsFeedPicker } from "@/components/SportsFeedPicker";
import type { SportsEntity, SportsFeedDefinition } from "@/lib/sportsFeedClient";
const globalKeys = ["DOMRect", "Element", "HTMLElement", "Node", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame", "MutationObserver"] as const;
const descriptors = new Map<string, PropertyDescriptor | undefined>();
beforeEach(() => {
 const values = {DOMRect:window.DOMRect,Element:window.Element,HTMLElement:window.HTMLElement,Node:window.Node,MutationObserver:window.MutationObserver,getComputedStyle:window.getComputedStyle.bind(window),requestAnimationFrame:(callback:FrameRequestCallback)=>setTimeout(()=>callback(performance.now()),0),cancelAnimationFrame:(handle:ReturnType<typeof setTimeout>)=>clearTimeout(handle)};
 for (const key of globalKeys) {descriptors.set(key,Object.getOwnPropertyDescriptor(globalThis,key));Object.defineProperty(globalThis,key,{configurable:true,writable:true,value:values[key]});}
});
afterEach(async () => {await act(async()=>{cleanup();await new Promise(resolve=>setTimeout(resolve,0));});for(const key of globalKeys){const descriptor=descriptors.get(key);if(descriptor)Object.defineProperty(globalThis,key,descriptor);else Reflect.deleteProperty(globalThis,key);}});
async function click(element:HTMLElement) {await act(async()=>{fireEvent.click(element);await new Promise(resolve=>setTimeout(resolve,10));});}
const entities:SportsEntity[]=[{id:"sport",name:"American Football",kind:"sport",competitionIDs:[],aliases:[],active:true},{id:"league",name:"NFL",kind:"competition",sportID:"sport",competitionIDs:[],aliases:[],active:true},{id:"team",name:"Buffalo Bills",kind:"team",sportID:"sport",competitionIDs:["league"],aliases:[],active:true}];
const definitions:SportsFeedDefinition[]=[{id:"sports",title:"Sports",kind:"global",entityIDs:[],description:"Global"},...entities.map(entity=>({id:entity.id,title:entity.name,kind:entity.kind,entityIDs:[entity.id],description:"Matching",groupPath:entity.kind==="team"?["Teams","American Football","NFL","AFC","East"]:entity.kind==="competition"?["Competitions","American Football"]:["Sports"]}))];
it("drills sport to competition to conference and selects a matching team",async()=>{
 const selected:string[]=[];
 render(<SportsFeedPicker definitions={definitions} entities={entities} feedID="sports" entitySearch="" onFeedChange={id=>selected.push(id)}/>);
 await click(screen.getByRole("button",{name:"Sports Feed"}));
 expect(screen.queryByRole("button",{name:"Buffalo Bills"})).toBeNull();
 await click(screen.getByRole("button",{name:"Football"}));
 expect(screen.getByRole("button",{name:"All Football"})).toBeTruthy();
 await click(screen.getByRole("button",{name:"NFL"}));
 expect(screen.getByRole("button",{name:"All NFL"})).toBeTruthy();
 expect(document.activeElement).toBe(screen.getByRole("button",{name:"All NFL"}));
 await click(screen.getByRole("button",{name:"AFC"}));
 await click(screen.getByRole("button",{name:"East"}));
 expect(screen.getByRole("navigation",{name:"East Feeds"})).toBeTruthy();
 await click(screen.getByRole("button",{name:"Buffalo Bills"}));
 expect(selected).toEqual(["team"]);
 expect(screen.queryByRole("navigation")).toBeNull();
});
it("offers back navigation and keeps external search a direct jump",async()=>{
 const mounted=render(<SportsFeedPicker definitions={definitions} entities={entities} feedID="sports" entitySearch=""/>);
 await click(screen.getByRole("button",{name:"Sports Feed"}));
 await click(screen.getByRole("button",{name:"Football"}));
 await click(screen.getByRole("button",{name:"Back"}));
 expect(screen.getByRole("button",{name:"Football"})).toBeTruthy();
 await act(async()=>{mounted.rerender(<SportsFeedPicker definitions={definitions} entities={entities} feedID="sports" entitySearch="Bills"/>);await new Promise(resolve=>setTimeout(resolve,10));});
 expect(screen.getByRole("button",{name:"Buffalo Bills"})).toBeTruthy();
 expect(screen.queryByRole("button",{name:"Back"})).toBeNull();
});
it("bounds broad direct-search results and prompts refinement",async()=>{
 const many=Array.from({length:100},(_,i)=>({...definitions[3]!,id:String(i),title:`Team ${i}`}));
 render(<SportsFeedPicker definitions={many} feedID="sports" entitySearch="Team"/>);
 await click(screen.getByRole("button",{name:"Sports Feed"}));
 expect(screen.getByRole("status").textContent).toContain("Showing 50 of 100 Matches");
 expect(screen.queryByRole("button",{name:"Team 99"})).toBeNull();
});

it("supports Escape dismissal with focus returning to the trigger",async()=>{
 render(<SportsFeedPicker definitions={definitions} entities={entities} feedID="sports" entitySearch=""/>);
 const trigger=screen.getByRole("button",{name:"Sports Feed"});
 await click(trigger);
 await click(screen.getByRole("button",{name:"Football"}));
 await act(async()=>{fireEvent.keyDown(document.activeElement!,{key:"Escape"});await new Promise(resolve=>setTimeout(resolve,10));});
 expect(screen.queryByRole("navigation")).toBeNull();
 expect(document.activeElement).toBe(trigger);
});

it("navigates reviewed MLB conferences and divisions without changing matching feed IDs",async()=>{
 const baseball:SportsEntity={id:"baseball",name:"Baseball",kind:"sport",competitionIDs:[],aliases:[],active:true};
 const mlb:SportsEntity={id:"mlb",name:"MLB",kind:"competition",sportID:"baseball",competitionIDs:[],aliases:[],active:true};
 const yankees:SportsEntity={id:"yankees-id",name:"New York Yankees",kind:"team",sportID:"baseball",competitionIDs:["mlb"],aliases:[],active:true};
 const mets:SportsEntity={...yankees,id:"mets-id",name:"New York Mets"};
 const feeds:SportsFeedDefinition[]=[{id:"sports",title:"Sports",kind:"global",entityIDs:[],description:"Global"},{id:"entity:baseball",title:"Baseball",kind:"sport",entityIDs:[baseball.id],description:"Matching"},{id:"entity:mlb",title:"MLB",kind:"competition",entityIDs:[mlb.id],description:"Matching",groupPath:["Competitions","Baseball"]},{id:"entity:yankees-id",title:yankees.name,kind:"team",entityIDs:[yankees.id],description:"Matching",groupPath:["Teams","Baseball","MLB","American League","East"]},{id:"entity:mets-id",title:mets.name,kind:"team",entityIDs:[mets.id],description:"Matching",groupPath:["Teams","Baseball","MLB","National League","East"]}];
 const selected:string[]=[];
 render(<SportsFeedPicker definitions={feeds} entities={[baseball,mlb,yankees,mets]} feedID="sports" entitySearch="" onFeedChange={id=>selected.push(id)}/>);
 await click(screen.getByRole("button",{name:"Sports Feed"}));
 await click(screen.getByRole("button",{name:"Baseball"}));
 await click(screen.getByRole("button",{name:"MLB"}));
 expect(screen.getByRole("button",{name:"All MLB"})).toBeTruthy();
 expect(screen.queryByRole("button",{name:yankees.name})).toBeNull();
 await click(screen.getByRole("button",{name:/American\sLeague/}));
 await click(screen.getByRole("button",{name:"East"}));
 expect(screen.getByRole("button",{name:yankees.name})).toBeTruthy();
 expect(screen.queryByRole("button",{name:mets.name})).toBeNull();
 await click(screen.getByRole("button",{name:yankees.name}));
 expect(selected).toEqual(["entity:yankees-id"]);
});

it("defers catalog tree and search work until the corresponding popup mode is visible",async()=>{
 const tree=spyOn(PickerTree,"sportsFeedPickerTree");
 const search=spyOn(PickerTree,"sportsPickerSearch");
 try {
  const view=render(<SportsFeedPicker definitions={definitions} entities={entities} feedID="sports" entitySearch=""/>);
  expect(tree).not.toHaveBeenCalled();
  expect(search).not.toHaveBeenCalled();
  view.rerender(<SportsFeedPicker definitions={definitions} entities={entities} feedID="sports" entitySearch="Bills"/>);
  expect(tree).not.toHaveBeenCalled();
  expect(search).not.toHaveBeenCalled();
  await click(screen.getByRole("button",{name:"Sports Feed"}));
  expect(tree).not.toHaveBeenCalled();
  expect(search).toHaveBeenCalledTimes(1);
  expect(screen.getByRole("button",{name:"Buffalo Bills"})).toBeTruthy();
  expect(screen.getByRole("button",{name:"Sports"})).toBeTruthy();
  view.rerender(<SportsFeedPicker definitions={definitions} entities={entities} feedID="sports" entitySearch=""/>);
  expect(tree).toHaveBeenCalledTimes(1);
  await click(screen.getByRole("button",{name:"Football"}));
  expect(tree).toHaveBeenCalledTimes(1);
  expect(screen.getByRole("button",{name:"NFL"})).toBeTruthy();
 } finally {tree.mockRestore();search.mockRestore();}
});
