import { afterEach, expect, it, spyOn } from "bun:test";
import { cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { renderToString } from "react-dom/server";
import { rememberBrowserSportsVisibility, SPORTS_VISIBILITY_MAX_AGE_MS } from "@/lib/sportsTopicVisibility";
import type { ReactNode } from "react";
import { useSportsCatalog } from "@/hooks/useSportsCatalog";
import * as Client from "@/lib/sportsFeedClient";
import { sportsTopicIsVisible } from "@/lib/sportsFeedClient";
const originalEnv=process.env.NEXT_PUBLIC_APP_ENV;
const restores:(()=>void)[]=[];
afterEach(()=>{cleanup();restores.splice(0).forEach(restore=>restore());if(originalEnv===undefined)delete process.env.NEXT_PUBLIC_APP_ENV;else process.env.NEXT_PUBLIC_APP_ENV=originalEnv;window.localStorage.clear();});
const catalog=(enabled:boolean):Client.SportsCatalog=>({enabled,available:true,eventsEnabled:false,feeds:[],entities:[],version:"test"});
function harness(){const client=new QueryClient({defaultOptions:{queries:{retryDelay:0,gcTime:0}}});return {client,wrapper:({children}:{children:ReactNode})=><QueryClientProvider client={client}>{children}</QueryClientProvider>};}
it("retains confirmed Sports across remount and catalog timeout while user hiding and serveroff win",async()=>{
 process.env.NEXT_PUBLIC_APP_ENV="visibility-test-dev";
 const fetch=spyOn(Client,"getSportsCatalog").mockResolvedValue(catalog(true));restores.push(()=>fetch.mockRestore());
 const first=harness();const initial=renderHook(()=>useSportsCatalog(),{wrapper:first.wrapper});
 await waitFor(()=>expect(initial.result.current.confirmedEnabled).toBe(true));
 initial.unmount();first.client.clear();
 fetch.mockRejectedValue(new Error("Catalog timed out"));
 const second=harness();const failed=renderHook(()=>useSportsCatalog(),{wrapper:second.wrapper});
 await waitFor(()=>expect(failed.result.current.isError).toBe(true));
 expect(failed.result.current.data).toBeUndefined();
 expect(sportsTopicIsVisible(true,{enabled:failed.result.current.confirmedEnabled})).toBe(true);
 expect(sportsTopicIsVisible(false,{enabled:failed.result.current.confirmedEnabled})).toBe(false);
 fetch.mockResolvedValue(catalog(false));
 await failed.result.current.refetch();
 await waitFor(()=>expect(failed.result.current.confirmedEnabled).toBe(false));
 failed.unmount();second.client.clear();
});
it("initial unknown Production catalog failure never activates Sports",async()=>{
 process.env.NEXT_PUBLIC_APP_ENV="prod";
 const fetch=spyOn(Client,"getSportsCatalog").mockRejectedValue(new Error("Catalog timed out"));restores.push(()=>fetch.mockRestore());
 const {client,wrapper}=harness();const {result}=renderHook(()=>useSportsCatalog(),{wrapper});
 expect(result.current.confirmedEnabled).toBe(false);
 await waitFor(()=>expect(result.current.isError).toBe(true));
 expect(result.current.confirmedEnabled).toBe(false);
 client.clear();
});

it("expires stale serverdata as well as stored confirmations during outages",async()=>{
 process.env.NEXT_PUBLIC_APP_ENV="visibility-expiry-test";
 const fetch=spyOn(Client,"getSportsCatalog").mockRejectedValue(new Error("Catalog timed out"));restores.push(()=>fetch.mockRestore());
 const {client,wrapper}=harness();
 const timestamp=Date.now()-SPORTS_VISIBILITY_MAX_AGE_MS-1;
 client.setQueryData(["sportsCatalog"],catalog(true),{updatedAt:timestamp});
 rememberBrowserSportsVisibility("visibility-expiry-test",true,timestamp);
 const {result}=renderHook(()=>useSportsCatalog(),{wrapper});
 expect(result.current.confirmedEnabled).toBe(false);
 await waitFor(()=>expect(result.current.isError).toBe(true));
 expect(result.current.confirmedEnabled).toBe(false);
 client.clear();
});
it("uses the unknown server snapshot before hydration even with a browser confirmation",()=>{
 process.env.NEXT_PUBLIC_APP_ENV="visibility-ssr-test";
 rememberBrowserSportsVisibility("visibility-ssr-test",true,Date.now());
 const {client,wrapper:Wrapper}=harness();
 function Probe(){const query=useSportsCatalog();return <span>{query.confirmedEnabled ? "Sports Visible" : "Sports Hidden"}</span>;}
 expect(renderToString(<Wrapper><Probe/></Wrapper>)).toContain("Sports Hidden");
 client.clear();
});
