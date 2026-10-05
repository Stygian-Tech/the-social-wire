import { describe, expect, test } from "bun:test";
import { Lexicons } from "@atproto/lexicon";
import { readFileSync } from "node:fs";
import { join } from "node:path";
const read=(path:string)=>JSON.parse(readFileSync(join(import.meta.dir,"../app/thesocialwire",`${path}.json`),"utf8"));
const methods=["getFinance","getFinanceCatalog","getFinanceSectors","searchFinanceInstruments","recordFinanceComposition"];
const docs=[read("discovery/defs"),read("finance/selection"),read("preferences"),...methods.map(name=>read(`discovery/${name}`))];
const lexicons=new Lexicons(docs);
const nsid=(name:string)=>`app.thesocialwire.discovery.${name}`;
const instrument={id:"instrument-opaque",name:"Company",symbol:"COMP",kind:"equity",providerID:"figi-id",aliases:[],sectorIDs:["technology"],isActive:true};
describe("Finance public contracts",()=>{
 test("publishes bounded canonical feed definitions",()=>{
  const feed={id:"group:mag7",title:"Mag7",kind:"group",instrumentIDs:[instrument.id],sectorIDs:[],description:"Matching company news"};
  const catalog={enabled:true,available:true,widgetsEnabled:false,feeds:[feed]};
  expect(()=>lexicons.assertValidXrpcOutput(nsid("getFinanceCatalog"),catalog)).not.toThrow();
  for(const invalid of [{...feed,kind:"portfolio"},{...feed,id:"x".repeat(257)},{...feed,instrumentIDs:["x".repeat(129)]}])
   expect(()=>lexicons.assertValidXrpcOutput(nsid("getFinanceCatalog"),{...catalog,feeds:[invalid]})).toThrow();
  expect(()=>lexicons.assertValidXrpcOutput(nsid("getFinanceCatalog"),{...catalog,feeds:undefined})).toThrow();
 });
 test("accepts bounded reviewed exchange names without requiring them in old snapshots",()=>{
  for(const value of [instrument,{...instrument,exchange:"UW",exchangeName:"Nasdaq Global Select Market"}])
   expect(()=>lexicons.assertValidXrpcOutput(nsid("searchFinanceInstruments"),{instruments:[value]})).not.toThrow();
  expect(()=>lexicons.assertValidXrpcOutput(nsid("searchFinanceInstruments"),{instruments:[{...instrument,exchangeName:"x".repeat(161)}]})).toThrow();
 });
 test("stores only canonical interests with valid timestamps and a closed selection kind",()=>{
  const value={$type:"app.thesocialwire.finance.selection",kind:"instrument",reference:"instrument-opaque",createdAt:"2026-09-30T12:00:00Z",updatedAt:"2026-09-30T12:00:00Z"};
  expect(()=>lexicons.assertValidRecord(value.$type,value)).not.toThrow();
  for(const kind of ["holdings","balance",""])expect(()=>lexicons.assertValidRecord(value.$type,{...value,kind})).toThrow();
  expect(()=>lexicons.assertValidRecord(value.$type,{...value,reference:"x".repeat(129)})).toThrow();
  expect(Object.keys(read("finance/selection").defs.main.record.properties)).toEqual(["kind","reference","createdAt","updatedAt"]);
 });
 test("bounds query contexts and search input",()=>{
  expect(()=>lexicons.assertValidXrpcParams(nsid("getFinance"),{feed:"group:mag7",limit:30,lang:"en",region:"outside-us",refreshSelections:true})).not.toThrow();
  for(const params of [{feed:"x".repeat(257)},{limit:51},{limit:0},{region:"precise-location"},{cursor:"x".repeat(4097)}])expect(()=>lexicons.assertValidXrpcParams(nsid("getFinance"),params)).toThrow();
  expect(()=>lexicons.assertValidXrpcParams(nsid("searchFinanceInstruments"),{})).toThrow();
  expect(()=>lexicons.assertValidXrpcParams(nsid("searchFinanceInstruments"),{q:"x".repeat(201)})).toThrow();
 });
 test("uses bounded integer basis points for confidence",()=>{
  const page={feedId:"finance",generationId:"generation",generatedAt:"2026-09-30T12:00:00Z",expiresAt:"2026-10-02T12:00:00Z",language:"en",preferenceRevision:"fingerprint",source:"ranked",widgetsEnabled:false,degraded:false,items:[{story:{itemId:"story",canonicalUrl:"https://example.com/story",title:"Company Earnings",source:{name:"Example",domain:"example.com"},reasons:[],provenance:[]},instruments:[{instrument,confidenceBps:9500,prominence:0,evidence:["name"]}],sectorIDs:["technology"],materiality:"earnings",majorGlobal:true,macroTopics:["inflation","monetary-policy"]}]};
  expect(()=>lexicons.assertValidXrpcOutput(nsid("getFinance"),page)).not.toThrow();
  expect(()=>lexicons.assertValidXrpcOutput(nsid("getFinance"),{...page,widgetsEnabled:undefined})).toThrow();
  expect(read("discovery/defs").defs.financeMatchedInstrument.properties.confidenceBps).toMatchObject({type:"integer",minimum:0,maximum:10000});
  for (const confidenceBps of [-1,10001,0.95]) expect(()=>lexicons.assertValidXrpcOutput(nsid("getFinance"), {...page,items:[{...page.items[0],instruments:[{instrument,confidenceBps,prominence:0,evidence:[]}]}]})).toThrow();
 });
 test("accepts only documented analytics events and suggestion counts",()=>{
  for(const event of ["impression","selection","removal","published"])expect(()=>lexicons.assertValidXrpcInput(nsid("recordFinanceComposition"),{event,suggestionCount:3})).not.toThrow();
  for(const value of [{event:"draft",suggestionCount:1},{event:"selection",suggestionCount:4},{event:"selection",suggestionCount:-1}])expect(()=>lexicons.assertValidXrpcInput(nsid("recordFinanceComposition"),value)).toThrow();
  expect(Object.keys(read("discovery/recordFinanceComposition").defs.main.input.schema.properties)).toEqual(["event","suggestionCount"]);
 });
 test("Finance visibility and market display remain optional additive preferences",()=>{
  const properties=read("preferences").defs.main.record.properties;
  expect(properties.showFinance.type).toBe("boolean");expect(properties.hideFinancePerformance.type).toBe("boolean");
  expect(read("preferences").defs.main.record.required).not.toContain("showFinance");
  expect(read("preferences").defs.main.record.required).not.toContain("hideFinancePerformance");
 });
});

test("Finance crypto exclusion and asset groups remain additive", () => {
  expect(read("preferences").defs.main.record.properties.hideFinanceCrypto.type).toBe("boolean");
  expect(read("discovery/getFinance").defs.main.parameters.properties.hideCrypto.type).toBe("boolean");
  expect(read("discovery/defs").defs.financeFeedDefinition.properties.assetKind.knownValues).toEqual(["stock", "etf", "crypto", "index", "commodity"]);
});
