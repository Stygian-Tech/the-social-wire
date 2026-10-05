import { describe, expect, spyOn, test } from "bun:test";
import { getSports, getSportsEvents, sportsTopicIsVisible, reorderSportsItems, sportsPreferenceFingerprint, sportsSelectionKey, type SportsEntity, type SportsItem, type SportsSelection } from "@/lib/sportsFeedClient";
import * as WireClient from "@/lib/wireFeedClient";
import { mergePreferencesRecord } from "@/lib/pdsClient";
const team:SportsEntity={id:"team-a",name:"Team A",kind:"team",sportID:"basketball",competitionIDs:["league-a"],aliases:[],active:true};
const selection=(reference:string,action:SportsSelection["action"]):SportsSelection=>({reference,action,createdAt:"now",updatedAt:"now"});
const article=(id:string,entities:SportsEntity[]=[],majorGlobal=false):SportsItem=>({story:{itemId:id,canonicalUrl:`https://example.com/${id}`,title:id,source:{name:"Example",domain:"example.com"},reasons:[],provenance:[]},entities,associations:[],majorGlobal,materiality:"general"});
describe("Sports client invariants",()=>{
 test("navigation remains hidden until visible mode is confirmed and respects user hiding",()=>{expect(sportsTopicIsVisible(true)).toBe(false);expect(sportsTopicIsVisible(true,{enabled:false})).toBe(false);expect(sportsTopicIsVisible(true,{enabled:true})).toBe(true);expect(sportsTopicIsVisible(false,{enabled:true})).toBe(false);});
 test("one deterministic identity per entity supports switching follow to mute",async()=>{expect(await sportsSelectionKey(team.id)).toHaveLength(64);expect(await sportsSelectionKey(team.id)).toBe(await sportsSelectionKey(team.id));expect(sportsPreferenceFingerprint([selection(team.id,"follow")])).not.toBe(sportsPreferenceFingerprint([selection(team.id,"mute")]));});
 test("specific follow overrides broad mute while explicit person or team mute wins",()=>{const items=[article("team",[team]),article("global",[],true)];expect(reorderSportsItems(items,[selection("basketball","mute")]).map(i=>i.story.itemId)).toEqual(["global"]);expect(reorderSportsItems(items,[selection("basketball","mute"),selection(team.id,"follow")]).map(i=>i.story.itemId)).toContain("team");expect(reorderSportsItems(items,[selection("basketball","follow"),selection(team.id,"mute")]).map(i=>i.story.itemId)).toEqual(["global"]);});
 test("sport and competition-only stories obey immediate mutes without concrete associations",()=>{const item={...article("sector-only"),sportIDs:["basketball"],competitionIDs:["league-a"]};expect(reorderSportsItems([item],[selection("basketball","mute")])).toEqual([]);expect(reorderSportsItems([item],[selection("league-a","mute")])).toEqual([]);});
 test("broad reordering reserves the fifth major story; matching-only preserves candidate order",()=>{const items=Array.from({length:10},(_,i)=>article(String(i),i===1?[team]:[],i===9));expect(reorderSportsItems(items,[selection(team.id,"follow")])[4]?.story.itemId).toBe("9");expect(reorderSportsItems(items,[selection(team.id,"follow")],false)).toEqual(items);});
 test("unrelated writes preserve Sports display and score privacy",()=>{const previous=mergePreferencesRecord({showSports:false,hideSportsScores:true},null);const changed=mergePreferencesRecord({rssArticleOpenMode:"reader"},previous);expect(changed.showSports).toBe(false);expect(changed.hideSportsScores).toBe(true);});
 test("requests bind feed language and cursor; cross-feed responses are rejected",async()=>{const paths:string[]=[];const fetch=spyOn(WireClient,"discoveryGatewayFetch").mockImplementation(async({path})=>{paths.push(path);return Response.json({feedId:"entity:team-a",items:[]});});try{await getSports({feed:"entity:team-a",cursor:"cursor",language:"fr"});const url=new URL(paths[0]!,"https://example.com");expect(url.searchParams.get("cursor")).toBe("cursor");expect(url.searchParams.get("lang")).toBe("fr");await expect(getSports({feed:"sports"})).rejects.toThrow("different feed");}finally{fetch.mockRestore();}});
});

test("team event requests encode sorted IDs and reject unscoped results", async () => {
 const paths:string[]=[];
 const fetch=spyOn(WireClient,"discoveryGatewayFetch").mockImplementation(async({path})=>{paths.push(path);return Response.json({events:[{id:"game",entityIDs:["other-team"]}],standings:[]});});
 try {
  await expect(getSportsEvents("entity:league",undefined,["team-b","team-a","team-a"])).rejects.toThrow("different scope");
  const url=new URL(paths[0]!,"https://example.com");expect(url.searchParams.get("teamIDs")).toBe("team-a,team-b");expect(url.searchParams.get("feed")).toBe("entity:league");
 } finally {fetch.mockRestore();}
});

test("interest scope binds sorted follows and timezone and rejects legacy global responses", async () => {
 const paths:string[]=[];let echo=false;
 const fetch=spyOn(WireClient,"discoveryGatewayFetch").mockImplementation(async({path})=>{paths.push(path);return Response.json({events:[],...(echo?{preferredIDs:["league-a","team-a"],timeZone:"America/New_York"}:{})});});
 try {
  const context={preferredIDs:["team-a","league-a","team-a"],timeZone:"America/New_York"};
  await expect(getSportsEvents("sports",undefined,undefined,context)).rejects.toThrow("different interest scope");echo=true;
  expect((await getSportsEvents("sports",undefined,undefined,context)).events).toEqual([]);
  const url=new URL(paths[0]!,"https://example.com");expect(url.searchParams.get("preferredIDs")).toBe("league-a,team-a");expect(url.searchParams.get("timeZone")).toBe("America/New_York");
 } finally {fetch.mockRestore();}
});

test("loaded articles give direct follows more weight than competitions and sports", () => {
 const items=Array.from({length:30},(_,i)=>({...article(String(i),i===2?[team]:[]),sportIDs:i===0?["swimming"]:[],competitionIDs:i===1?["league-b"]:[]}));
 const ranked=reorderSportsItems(items,[selection(team.id,"follow"),selection("league-b","follow"),selection("swimming","follow")]);
 expect(ranked.slice(0,3).map(item=>item.story.itemId)).toEqual(["2","1","0"]);
});


test("team scope accepts whole relevant league tables and unavailable coverage", async () => {
 const table = {competitionID:"league-a",season:"2026",sourceURL:"https://www.thesportsdb.com/",status:"available",degraded:false,rows:[{id:"rival",entityID:"team-b",name:"Rival",rank:1},{id:"followed",entityID:"team-a",name:"Followed",rank:8},{id:"unresolved",name:"Unresolved",rank:9}]};
 let standings = [table];
 const fetch = spyOn(WireClient,"discoveryGatewayFetch").mockImplementation(async()=>Response.json({events:[{id:"game",entityIDs:["team-a","team-b"]}],standings}));
 try {
  expect((await getSportsEvents("sports",undefined,["team-a"])).standings?.[0]?.rows).toEqual(table.rows);
  standings = [{...table,status:"unavailable",rows:[]}];
  expect((await getSportsEvents("sports",undefined,["team-a"])).standings?.[0]?.rows).toEqual([]);
  standings = [{...table,rows:table.rows.filter(row=>row.entityID!=="team-a")}];
  await expect(getSportsEvents("sports",undefined,["team-a"])).rejects.toThrow("different scope");
 } finally {fetch.mockRestore();}
});
