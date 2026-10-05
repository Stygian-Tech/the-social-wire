import { expect, it } from "bun:test";
import { readSportsVisibility, rememberSportsVisibility, sportsVisibilityStorageKey, SPORTS_VISIBILITY_MAX_AGE_MS } from "@/lib/sportsTopicVisibility";
const now=1_000_000_000;
function storage(){const map=new Map<string,string>();return {getItem:(key:string)=>map.get(key)??null,setItem:(key:string,value:string)=>{map.set(key,value);}};}
it("requires a valid server confirmation and preserves enabled through storage failure",()=>{
 const cache=storage();
 expect(readSportsVisibility(cache,"prod","https://unknown.example",now)).toBeUndefined();
 const blocked={getItem:()=>{throw new Error("blocked");},setItem:()=>{throw new Error("blocked");}};
 rememberSportsVisibility(blocked,"dev","https://blocked.example",true,now);
 expect(readSportsVisibility(blocked,"dev","https://blocked.example",now+1)).toBe(true);
});
it("explicit disabled replaces enabled and confirmations expire after24hours",()=>{
 const cache=storage();
 rememberSportsVisibility(cache,"dev","https://expiry.example",true,now);
 expect(readSportsVisibility(cache,"dev","https://expiry.example",now+SPORTS_VISIBILITY_MAX_AGE_MS-1)).toBe(true);
 expect(readSportsVisibility(cache,"dev","https://expiry.example",now+SPORTS_VISIBILITY_MAX_AGE_MS)).toBeUndefined();
 rememberSportsVisibility(cache,"dev","https://expiry.example",false,now+1);
 expect(readSportsVisibility(cache,"dev","https://expiry.example",now+2)).toBe(false);
 rememberSportsVisibility(cache,"dev","https://expiry.example",true,now);
 expect(readSportsVisibility(cache,"dev","https://expiry.example",now+2)).toBe(false);
});
it("isolates origins and environments and ignores malformed or future confirmations",()=>{
 const cache=storage();
 rememberSportsVisibility(cache,"dev","https://dev.example",true,now);
 expect(readSportsVisibility(cache,"prod","https://dev.example",now)).toBeUndefined();
 expect(readSportsVisibility(cache,"dev","https://prod.example",now)).toBeUndefined();
 cache.setItem(sportsVisibilityStorageKey("prod","https://malformed.example"),'{"enabled":"true","confirmedAt":1}');
 expect(readSportsVisibility(cache,"prod","https://malformed.example",now)).toBeUndefined();
 cache.setItem(sportsVisibilityStorageKey("prod","https://future.example"),JSON.stringify({enabled:true,confirmedAt:now+1}));
 expect(readSportsVisibility(cache,"prod","https://future.example",now)).toBeUndefined();
 cache.setItem(sportsVisibilityStorageKey("prod","https://future-new.example"),JSON.stringify({enabled:true,confirmedAt:Date.now()+999_999}));
 rememberSportsVisibility(cache,"prod","https://future-new.example",false,now);
 expect(readSportsVisibility(cache,"prod","https://future-new.example",now)).toBe(false);
});
