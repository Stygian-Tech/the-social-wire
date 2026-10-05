import { expect, test } from "bun:test";
import { QueryClient, dehydrate, hydrate } from "@tanstack/react-query";
import { financeTopicIsVisible } from "@/lib/financeFeedClient";
import { DEFAULT_FEED_DISPLAY_PREFERENCES } from "@/lib/feedPreferences";
import { shouldPersistFinanceQuery } from "@/lib/financeQueryPersist";

test("Finance default visibility still requires server visible mode and respects explicit hiding", () => {
 const show = DEFAULT_FEED_DISPLAY_PREFERENCES.showFinance;
 expect(show).toBe(true);
 expect(financeTopicIsVisible(show)).toBe(false);
 expect(financeTopicIsVisible(show,{enabled:false})).toBe(false);
 expect(financeTopicIsVisible(show,{enabled:true})).toBe(true);
 expect(financeTopicIsVisible(false,{enabled:true})).toBe(false);
});

test("current scoped Finance keys persist and hydrate only bounded unexpired generations", () => {
 const writer = new QueryClient(); const reader = new QueryClient();
 const key = ["financeEntries","finance","did:plc:viewer","en","US","viewer","[]",0];
 const page = {items:[{id:"one"}],expiresAt:new Date(Date.now()+60000).toISOString()};
 try {
  writer.setQueryData(key,{pages:[page],pageParams:[undefined]});
  writer.setQueryData(key.slice(0,7),{pages:[page],pageParams:[undefined]});
  writer.setQueryData([...key.slice(0,1),"expired",...key.slice(2)],{pages:[{...page,expiresAt:"2000-01-01"}],pageParams:[undefined]});
  writer.setQueryData([...key.slice(0,1),"oversized",...key.slice(2)],{pages:[{...page,items:Array(151).fill({})}],pageParams:[undefined]});
  writer.setQueryData([...key.slice(0,1),"too-many-pages",...key.slice(2)],{pages:Array(4).fill(page),pageParams:Array(4).fill(undefined)});
  const payload=dehydrate(writer,{shouldDehydrateQuery:shouldPersistFinanceQuery});
  expect(payload.queries).toHaveLength(1);
  hydrate(reader,payload);
  expect(reader.getQueryData<unknown>(key)).toEqual({pages:[page],pageParams:[undefined]});
  expect(reader.getQueryData([...key.slice(0,2),"did:plc:other",...key.slice(3)])).toBeUndefined();
  expect(reader.getQueryData([...key.slice(0,7),1])).toBeUndefined();
 } finally {writer.clear();reader.clear();}
});
