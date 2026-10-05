import { expect, it } from "bun:test";
import { sportsFeedPickerGroups } from "@/lib/sportsFeedPickerGroups";
import type { SportsFeedDefinition } from "@/lib/sportsFeedClient";
const feed = (id: string, path: string[] = [], kind = "ncaa-team"): SportsFeedDefinition => ({id,title:`Team ${id}`,kind,description:"Matching stories",entityIDs:[id],groupPath:path});
it("finds catalog aliases such as RBR without conflating Racing Bulls", () => {
 const redBull = {...feed("red-bull", ["Motorsport", "Formula 1"], "team"), title: "Red Bull Racing", searchAliases: ["RBR"]};
 const racingBulls = {...feed("racing-bulls", ["Motorsport", "Formula 1"], "team"), title: "Racing Bulls", searchAliases: ["VCARB"]};
 expect(sportsFeedPickerGroups([redBull, racingBulls], "sports", "RBR").flatMap(group => group.feeds.map(item => item.id))).toEqual(["red-bull"]);
});
it("does not repeat the kind when catalog paths already include it", () => {
 expect(sportsFeedPickerGroups([feed("nba", ["Teams", "Basketball", "NBA"], "team")], "sports", "")[0]?.label).toBe("Teams › Basketball › NBA");
});
it("breaks teams into sport, division, and conference groups without conflating names", () => {
 const groups=sportsFeedPickerGroups([feed("a",["Football","Division II","Gulf South"]),feed("b",["Basketball","Division II","Gulf South"]),feed("c",["Football","Division III","Centennial"])],"sports","");
 expect(groups.map(g=>g.label)).toEqual(["NCAA Teams › Basketball › Division II › Gulf South","NCAA Teams › Football › Division II › Gulf South","NCAA Teams › Football › Division III › Centennial"]);
 expect(new Set(groups.map(g=>g.id)).size).toBe(3);
});
it("makes every team browsable beyond the old100-per-kind cap, including the selected row", () => {
 const definitions=Array.from({length:250},(_,i)=>feed(`${i}`,["Football","Division III","Centennial"]));
 const groups=sportsFeedPickerGroups(definitions,"249","");
 expect(groups.flatMap(g=>g.feeds).length).toBe(250);
 expect(groups.flatMap(g=>g.feeds).some(f=>f.id==="249")).toBe(true);
});
it("searches conference and division paths while retaining selection and global coverage", () => {
 const all={...feed("sports",[],"global"),title:"Sports",entityIDs:[]};
 const definitions=[all,feed("d2",["Football","Division II","Gulf South"]),feed("d3",["Football","Division III","Centennial"])];
 expect(sportsFeedPickerGroups(definitions,"d3","gulf south").flatMap(g=>g.feeds.map(f=>f.id))).toEqual(["sports","d2","d3"]);
 expect(sportsFeedPickerGroups(definitions,"sports","division iii").flatMap(g=>g.feeds.map(f=>f.id))).toEqual(["sports","d3"]);
});
it("supports old catalogs and retains deliberate person search gating", () => {
 const old={id:"old",title:"Legacy",kind:"team",entityIDs:["old"],description:"Legacy Feed"};
 const person=feed("driver",["Motorsport","Formula 1"],"driver");
 expect(sportsFeedPickerGroups([old,person],"old","").flatMap(g=>g.feeds.map(f=>f.id))).toEqual(["old"]);
 expect(sportsFeedPickerGroups([old,person],"driver","").flatMap(g=>g.feeds.map(f=>f.id))).toEqual(["old","driver"]);
 expect(sportsFeedPickerGroups([old,person],"old","formula 1").flatMap(g=>g.feeds.map(f=>f.id))).toEqual(["old","driver"]);
});

it("shows para swimming classes and medley indices as distinct browsable groups", () => {
 const classes: SportsFeedDefinition[] = [
  {id:"entity:s14",title:"Para Swimming S14",kind:"classification",description:"Matching stories",entityIDs:["s14"],groupPath:["Classes and Medley Indices","Swimming","Para Swimming","Freestyle, Backstroke and Butterfly"]},
  {id:"entity:sb14",title:"Para Swimming SB14",kind:"classification",description:"Matching stories",entityIDs:["sb14"],groupPath:["Classes and Medley Indices","Swimming","Para Swimming","Breaststroke"]},
  {id:"entity:sm14",title:"Para Swimming SM14",kind:"classification",description:"Matching stories",entityIDs:["sm14"],groupPath:["Classes and Medley Indices","Swimming","Para Swimming","Individual Medley"]},
 ];
 const groups=sportsFeedPickerGroups(classes,"sports","");
 expect(groups).toHaveLength(3);
 expect(new Set(groups.map(group=>group.id)).size).toBe(3);
 expect(groups.map(group=>group.label)).toEqual([
  "Classes and Medley Indices › Swimming › Para Swimming › Breaststroke",
  "Classes and Medley Indices › Swimming › Para Swimming › Freestyle, Backstroke and Butterfly",
  "Classes and Medley Indices › Swimming › Para Swimming › Individual Medley",
 ]);
 expect(groups.flatMap(group=>group.feeds.map(item=>item.id)).sort()).toEqual(["entity:s14","entity:sb14","entity:sm14"]);
 for(const [query,id] of [["S14","entity:s14"],["SB14","entity:sb14"],["SM14","entity:sm14"]]) {
  expect(sportsFeedPickerGroups(classes,"sports",query!).flatMap(group=>group.feeds.map(item=>item.id))).toEqual([id!]);
 }
 expect(sportsFeedPickerGroups(classes,"sports","Breaststroke").flatMap(group=>group.feeds.map(item=>item.id))).toEqual(["entity:sb14"]);
 expect(sportsFeedPickerGroups(classes,"sports","Individual Medley").flatMap(group=>group.feeds.map(item=>item.id))).toEqual(["entity:sm14"]);
});
