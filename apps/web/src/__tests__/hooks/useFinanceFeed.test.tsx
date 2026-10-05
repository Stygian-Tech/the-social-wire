import { afterEach, beforeEach, describe, expect, it, mock } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ReactNode } from "react";
import { WIRE_MODERATION_RPC_SCOPES } from "@/lib/atprotoOAuthScopes";
import { useFinanceFeed } from "@/hooks/useFinanceFeed";
import type { FinancePage, FinanceSelection } from "@/lib/financeFeedClient";
const realAuth={...await import("@/hooks/useAuth")};
const realFinance={...await import("@/lib/financeFeedClient")};
let oauth:OAuthSession;
let client:QueryClient;
let records:FinanceSelection[];
let writeFailed=false;
let requests=0;
const page:FinancePage={feedId:"finance",generationId:"old",generatedAt:"now",expiresAt:"2099-01-01",language:"en",preferenceRevision:"empty",source:"ranked",degraded:false,widgetsEnabled:false,cursor:"old-cursor",items:[{story:{itemId:"story",title:"Story",canonicalUrl:"https://example.com/story",source:{name:"Example",domain:"example.com"},reasons:[],provenance:[]},instruments:[],sectorIDs:[],majorGlobal:true}]};
function wrapper({children}:{children:ReactNode}){return <QueryClientProvider client={client}>{children}</QueryClientProvider>;}
beforeEach(()=>{requests=0;writeFailed=false;records=[];oauth={did:"did:plc:alice",getTokenInfo:async()=>({scope:WIRE_MODERATION_RPC_SCOPES.join(" ")})} as unknown as OAuthSession;client=new QueryClient({defaultOptions:{queries:{retry:false},mutations:{retry:false}}});mock.module("@/hooks/useAuth",()=>({...realAuth,useAuth:()=>({session:{did:oauth.did},isLoading:false,oauthSessionReloadSeq:0,getOAuthSession:()=>oauth})}));mock.module("@/lib/financeFeedClient",()=>({...realFinance,getFinanceCatalog:async()=>({enabled:true,available:true,widgetsEnabled:false,feeds:[]}),listFinanceSelections:async()=>records,writeFinanceSelection:async(_oauth:unknown,_did:unknown,selection:FinanceSelection)=>{if(writeFailed)throw new Error("offline");records=[selection];},getFinance:async()=>{requests++;return {...page,generationId:requests>1?"new":"old"};}}));});
afterEach(()=>{cleanup();client.clear();mock.module("@/hooks/useAuth",()=>realAuth);mock.module("@/lib/financeFeedClient",()=>realFinance);});
describe("Finance generation handoff",()=>{
 it("keeps loaded articles and suspends continuation until explicit refresh after a selection",async()=>{const {result}=renderHook(()=>useFinanceFeed(),{wrapper});await waitFor(()=>expect(result.current.items).toHaveLength(1));await act(async()=>{await result.current.saveSelection({selection:{kind:"sector",reference:"technology",createdAt:"now",updatedAt:"now"},remove:false});});expect(result.current.items).toHaveLength(1);expect(result.current.suspended).toBe(true);expect(requests).toBe(1);await act(async()=>{await result.current.refresh();});await waitFor(()=>expect(result.current.suspended).toBe(false));expect(result.current.feed.data?.pages).toHaveLength(1);expect(result.current.feed.data?.pages[0]?.generationId).toBe("new");});
 it("rolls back failed public writes without replacing the committed generation",async()=>{const {result}=renderHook(()=>useFinanceFeed(),{wrapper});await waitFor(()=>expect(result.current.items).toHaveLength(1));writeFailed=true;await act(async()=>{try{await result.current.saveSelection({selection:{kind:"sector",reference:"technology",createdAt:"now",updatedAt:"now"},remove:false});}catch{}});await waitFor(()=>expect(result.current.suspended).toBe(false));expect(result.current.selections).toHaveLength(0);expect(result.current.feed.data?.pages[0]?.generationId).toBe("old");});
 it("does not install a delayed refresh after switching accounts",async()=>{
  let resolve!: (page:FinancePage)=>void;
  const delayed=new Promise<FinancePage>(done=>{resolve=done;});
  let started=false;
  mock.module("@/lib/financeFeedClient",()=>({...realFinance,listFinanceSelections:async()=>records,getFinance:async(args:{refreshSelections?:boolean;oauthSession?:OAuthSession})=>{if(args.refreshSelections){started=true;return delayed;}return {...page,generationId:args.oauthSession?.did ?? "public"};}}));
  const {result,rerender}=renderHook(()=>useFinanceFeed(),{wrapper});
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
  mock.module("@/lib/financeFeedClient",()=>({...realFinance,getFinanceCatalog:async()=>({enabled:true,available:true,widgetsEnabled:false,feeds:[]}),listFinanceSelections:async()=>records,getFinance:async(args:{feed?:string;cursor?:string})=>{requested.push(`${args.feed}:${args.cursor ?? "first"}`);return {...page,feedId:args.feed!,generationId:args.feed!,cursor:args.cursor ? undefined : `${args.feed}-cursor`,items:[{...page.items[0]!,story:{...page.items[0]!.story,itemId:args.feed!}}]};}}));
  const {result,rerender}=renderHook(({id})=>useFinanceFeed(id),{wrapper,initialProps:{id:"instrument:apple"}});
  await waitFor(()=>expect(result.current.items[0]?.story.itemId).toBe("instrument:apple"));
  await act(async()=>{await result.current.feed.fetchNextPage();});
  await waitFor(()=>expect(result.current.feed.data?.pages).toHaveLength(2));
  rerender({id:"industry:pharma"});
  expect(result.current.items).toHaveLength(0);
  await waitFor(()=>expect(result.current.items[0]?.story.itemId).toBe("industry:pharma"));
  expect(result.current.feed.data?.pages).toHaveLength(1);
  expect(requested).toContain("instrument:apple:instrument:apple-cursor");
  expect(requested).toContain("industry:pharma:first");
  expect(requested).not.toContain("industry:pharma:instrument:apple-cursor");
 });
 it("rejects a delayed refresh after switching named feeds",async()=>{
  let resolve!:(page:FinancePage)=>void;
  const delayed=new Promise<FinancePage>(done=>{resolve=done;});
  let started=false;
  mock.module("@/lib/financeFeedClient",()=>({...realFinance,getFinanceCatalog:async()=>({enabled:true,available:true,widgetsEnabled:false,feeds:[]}),listFinanceSelections:async()=>records,getFinance:async(args:{feed?:string;refreshSelections?:boolean})=>{if(args.refreshSelections){started=true;return delayed;}return {...page,feedId:args.feed!,generationId:args.feed!};}}));
  const {result,rerender}=renderHook(({id})=>useFinanceFeed(id),{wrapper,initialProps:{id:"instrument:apple"}});
  await waitFor(()=>expect(result.current.feed.data?.pages[0]?.feedId).toBe("instrument:apple"));
  let pending!:Promise<void>;
  act(()=>{pending=result.current.refresh();});
  await waitFor(()=>expect(started).toBe(true));
  rerender({id:"group:mag7"});
  await waitFor(()=>expect(result.current.feed.data?.pages[0]?.feedId).toBe("group:mag7"));
  await act(async()=>{resolve({...page,feedId:"instrument:apple",generationId:"late-apple"});await pending;});
  expect(result.current.feed.data?.pages[0]?.feedId).toBe("group:mag7");
  expect(result.current.refreshing).toBe(false);
 });
 it("keeps a named feed's matching order when global interests change",async()=>{
  mock.module("@/lib/financeFeedClient",()=>({...realFinance,getFinanceCatalog:async()=>({enabled:true,available:true,widgetsEnabled:false,feeds:[]}),listFinanceSelections:async()=>records,writeFinanceSelection:async(_oauth:unknown,_did:unknown,selection:FinanceSelection)=>{records=[selection];},getFinance:async()=>({...page,feedId:"group:mag7",items:[page.items[0]!,{...page.items[0]!,story:{...page.items[0]!.story,itemId:"selected"},instruments:[{instrument:{id:"apple",name:"Apple",symbol:"AAPL",kind:"equity"},confidenceBps:9900,prominence:1}]}]})}));
  const {result}=renderHook(()=>useFinanceFeed("group:mag7"),{wrapper});
  await waitFor(()=>expect(result.current.items).toHaveLength(2));
  await act(async()=>{await result.current.saveSelection({selection:{kind:"instrument",reference:"apple",createdAt:"now",updatedAt:"now"},remove:false});});
  expect(result.current.items.map(item=>item.story.itemId)).toEqual(["story","selected"]);
  expect(result.current.suspended).toBe(true);
 });

});
