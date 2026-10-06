import { afterEach, beforeEach, describe, expect, it, mock } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ReactNode } from "react";
import { WIRE_MODERATION_RPC_SCOPES } from "@/lib/atprotoOAuthScopes";
import { useSportsFeed } from "@/hooks/useSportsFeed";
import type { SportsPage, SportsSelection } from "@/lib/sportsFeedClient";
const realDummy={...await import("@/lib/dummyReaderData")};
const realAuth={...await import("@/hooks/useAuth")};
const realSports={...await import("@/lib/sportsFeedClient")};
let oauth:OAuthSession;
let client:QueryClient;
let records:SportsSelection[];
let writeFailed=false;
let requests=0;
const page:SportsPage={feedId:"sports",generationId:"old",generatedAt:"now",expiresAt:"2099-01-01",language:"en",preferenceRevision:"empty",source:"ranked",degraded:false,eventsEnabled:false,cursor:"old-cursor",items:[{story:{itemId:"story",title:"Story",canonicalUrl:"https://example.com/story",source:{name:"Example",domain:"example.com"},reasons:[],provenance:[]},entities:[],associations:[],materiality:"general",majorGlobal:true}]};
function wrapper({children}:{children:ReactNode}){return <QueryClientProvider client={client}>{children}</QueryClientProvider>;}
beforeEach(()=>{requests=0;writeFailed=false;records=[];oauth={did:"did:plc:alice",getTokenInfo:async()=>({scope:WIRE_MODERATION_RPC_SCOPES.join(" ")})} as unknown as OAuthSession;client=new QueryClient({defaultOptions:{queries:{retry:false},mutations:{retry:false}}});mock.module("@/hooks/useAuth",()=>({...realAuth,useAuth:()=>({session:{did:oauth.did},isLoading:false,oauthSessionReloadSeq:0,getOAuthSession:()=>oauth})}));mock.module("@/lib/sportsFeedClient",()=>({...realSports,getSportsCatalog:async()=>({enabled:true,available:true,eventsEnabled:false,feeds:[]}),listSportsSelections:async()=>records,writeSportsSelection:async(_oauth:unknown,_did:unknown,selection:SportsSelection)=>{if(writeFailed)throw new Error("offline");records=[selection];},getSports:async()=>{requests++;return {...page,generationId:requests>1?"new":"old"};}}));});
afterEach(()=>{cleanup();client.clear();mock.module("@/hooks/useAuth",()=>realAuth);mock.module("@/lib/sportsFeedClient",()=>realSports);mock.module("@/lib/dummyReaderData",()=>realDummy);});
describe("Sports generation handoff",()=>{
 it("serves the public baseline for the synthetic local account without inventing OAuth",async()=>{
  mock.module("@/lib/dummyReaderData",()=>({...realDummy,isDummyReaderDataEnabled:()=>true}));
  const {result}=renderHook(()=>useSportsFeed(),{wrapper});await waitFor(()=>expect(result.current.items).toHaveLength(1));expect(result.current.signedIn).toBe(false);expect(result.current.error).toBeNull();
 });
 it("keeps loaded articles and suspends continuation until explicit refresh after a selection",async()=>{const {result}=renderHook(()=>useSportsFeed(),{wrapper});await waitFor(()=>expect(result.current.items).toHaveLength(1));await act(async()=>{await result.current.saveSelection({selection:{action:"follow",reference:"technology",createdAt:"now",updatedAt:"now"},remove:false});});expect(result.current.items).toHaveLength(1);expect(result.current.suspended).toBe(true);expect(requests).toBe(1);await act(async()=>{await result.current.refresh();});await waitFor(()=>expect(result.current.suspended).toBe(false));expect(result.current.feed.data?.pages).toHaveLength(1);expect(result.current.feed.data?.pages[0]?.generationId).toBe("new");});
 it("rolls back failed public writes without replacing the committed generation",async()=>{const {result}=renderHook(()=>useSportsFeed(),{wrapper});await waitFor(()=>expect(result.current.items).toHaveLength(1));writeFailed=true;await act(async()=>{try{await result.current.saveSelection({selection:{action:"follow",reference:"technology",createdAt:"now",updatedAt:"now"},remove:false});}catch{}});await waitFor(()=>expect(result.current.suspended).toBe(false));expect(result.current.selections).toHaveLength(0);expect(result.current.feed.data?.pages[0]?.generationId).toBe("old");});
 it("does not install a delayed refresh after switching accounts",async()=>{
  let resolve!: (page:SportsPage)=>void;
  const delayed=new Promise<SportsPage>(done=>{resolve=done;});
  let started=false;
  mock.module("@/lib/sportsFeedClient",()=>({...realSports,listSportsSelections:async()=>records,getSports:async(args:{refreshSelections?:boolean;oauthSession?:OAuthSession})=>{if(args.refreshSelections){started=true;return delayed;}return {...page,generationId:args.oauthSession?.did ?? "public"};}}));
  const {result,rerender}=renderHook(()=>useSportsFeed(),{wrapper});
  await waitFor(()=>expect(result.current.feed.data?.pages[0]?.generationId).toBe("did:plc:alice"));
  let pending!:Promise<void>;
  act(()=>{pending=result.current.refresh();});
  await waitFor(()=>expect(started).toBe(true));
  oauth={...oauth,did:"did:plc:bob"} as unknown as OAuthSession;
  rerender();
  await waitFor(()=>expect(result.current.feed.data?.pages[0]?.generationId).toBe("did:plc:bob"));
  await act(async()=>{resolve({...page,generationId:"late-alice"});await pending;});
  expect(result.current.feed.data?.pages[0]?.generationId).toBe("did:plc:bob");
  expect(result.current.refreshing).toBe(false);
 });

 it("isolates named feeds and clears prior continuation on selection",async()=>{
  const requested:string[]=[];
  mock.module("@/lib/sportsFeedClient",()=>({...realSports,getSportsCatalog:async()=>({enabled:true,available:true,eventsEnabled:false,feeds:[]}),listSportsSelections:async()=>records,getSports:async(args:{feed?:string;cursor?:string})=>{requested.push(`${args.feed}:${args.cursor ?? "first"}`);return {...page,feedId:args.feed!,generationId:args.feed!,cursor:args.cursor ? undefined : `${args.feed}-cursor`,items:[{...page.items[0]!,story:{...page.items[0]!.story,itemId:args.feed!}}]};}}));
  const {result,rerender}=renderHook(({id})=>useSportsFeed(id),{wrapper,initialProps:{id:"entity:team-a"}});
  await waitFor(()=>expect(result.current.items[0]?.story.itemId).toBe("entity:team-a"));
  await act(async()=>{await result.current.feed.fetchNextPage();});
  await waitFor(()=>expect(result.current.feed.data?.pages).toHaveLength(2));
  rerender({id:"entity:league-a"});
  expect(result.current.items).toHaveLength(0);
  await waitFor(()=>expect(result.current.items[0]?.story.itemId).toBe("entity:league-a"));
  expect(result.current.feed.data?.pages).toHaveLength(1);
  expect(requested).toContain("entity:team-a:entity:team-a-cursor");
  expect(requested).toContain("entity:league-a:first");
  expect(requested).not.toContain("entity:league-a:entity:team-a-cursor");
 });
 it("rejects a delayed refresh after switching named feeds",async()=>{
  let resolve!:(page:SportsPage)=>void;
  const delayed=new Promise<SportsPage>(done=>{resolve=done;});
  let started=false;
  mock.module("@/lib/sportsFeedClient",()=>({...realSports,getSportsCatalog:async()=>({enabled:true,available:true,eventsEnabled:false,feeds:[]}),listSportsSelections:async()=>records,getSports:async(args:{feed?:string;refreshSelections?:boolean})=>{if(args.refreshSelections){started=true;return delayed;}return {...page,feedId:args.feed!,generationId:args.feed!};}}));
  const {result,rerender}=renderHook(({id})=>useSportsFeed(id),{wrapper,initialProps:{id:"entity:team-a"}});
  await waitFor(()=>expect(result.current.feed.data?.pages[0]?.feedId).toBe("entity:team-a"));
  let pending!:Promise<void>;
  act(()=>{pending=result.current.refresh();});
  await waitFor(()=>expect(started).toBe(true));
  rerender({id:"entity:league-a"});
  await waitFor(()=>expect(result.current.feed.data?.pages[0]?.feedId).toBe("entity:league-a"));
  await act(async()=>{resolve({...page,feedId:"entity:team-a",generationId:"late-apple"});await pending;});
  expect(result.current.feed.data?.pages[0]?.feedId).toBe("entity:league-a");
  expect(result.current.refreshing).toBe(false);
 });
 it("keeps a named feed's matching order when global interests change",async()=>{
  mock.module("@/lib/sportsFeedClient",()=>({...realSports,getSportsCatalog:async()=>({enabled:true,available:true,eventsEnabled:false,feeds:[]}),listSportsSelections:async()=>records,writeSportsSelection:async(_oauth:unknown,_did:unknown,selection:SportsSelection)=>{records=[selection];},getSports:async()=>({...page,feedId:"entity:league-a",items:[page.items[0]!,{...page.items[0]!,story:{...page.items[0]!.story,itemId:"selected"},entities:[{id:"team-a",name:"Team A",kind:"team",competitionIDs:[],aliases:[],active:true}]}]})}));
  const {result}=renderHook(()=>useSportsFeed("entity:league-a"),{wrapper});
  await waitFor(()=>expect(result.current.items).toHaveLength(2));
  await act(async()=>{await result.current.saveSelection({selection:{action:"follow",reference:"team-a",createdAt:"now",updatedAt:"now"},remove:false});});
  expect(result.current.items.map(item=>item.story.itemId)).toEqual(["story","selected"]);
  expect(result.current.suspended).toBe(true);
 });

});

it("loads Sports for a signed-in viewer with a confirmed empty selection collection", async () => {
 const {result}=renderHook(()=>useSportsFeed(),{wrapper});
 await waitFor(()=>expect(result.current.items).toHaveLength(1));
 expect(result.current.signedIn).toBe(true);
 expect(result.current.selections).toEqual([]);
 expect(result.current.selectionsLoading).toBe(false);
 expect(result.current.selectionsError).toBeNull();
 expect(result.current.error).toBeNull();
 expect(requests).toBe(1);
});

it("keeps genuine selection request failures visible rather than treating them as empty interests", async () => {
 const failure=new Error("PDS selection request failed");
 mock.module("@/lib/sportsFeedClient",()=>({...realSports,
  getSportsCatalog:async()=>({enabled:true,available:true,eventsEnabled:false,feeds:[],entities:[],version:"test"}),
  listSportsSelections:async()=>{throw failure;},
  getSports:async()=>{requests++;return page;},
 }));
 const {result}=renderHook(()=>useSportsFeed(),{wrapper});
 await waitFor(()=>expect(result.current.selectionsError).toBe(failure));
 expect(result.current.error).toBe(failure);
 expect(result.current.selectionsLoading).toBe(false);
 expect(requests).toBe(0);
});
