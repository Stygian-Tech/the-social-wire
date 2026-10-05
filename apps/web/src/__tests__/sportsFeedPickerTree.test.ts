import { expect, it } from "bun:test";
import { sportsFeedPickerTree, sportsPickerSearch } from "@/lib/sportsFeedPickerTree";
import type { SportsEntity, SportsFeedDefinition } from "@/lib/sportsFeedClient";
const entity = (id:string,name:string,kind:string,sportID?:string):SportsEntity=>({id,name,kind,sportID,competitionIDs:[],aliases:[],active:true});
const entities=[entity("football","American Football","sport"),entity("swimming","Swimming","sport"),entity("nfl","NFL","competition","football"),entity("team","Buffalo Bills","team","football"),entity("college","Mount Union Football","ncaa-team","football"),entity("class","S1","classification","swimming")];
const feed=(id:string,title:string,kind:string,groupPath:string[]=[]):SportsFeedDefinition=>({id,title,kind,entityIDs:[id],groupPath,description:"Matching Stories"});
const definitions=[feed("sports","Sports","global"),feed("football","American Football","sport",["Sports"]),feed("nfl","NFL","competition",["Competitions","American Football"]),feed("team","Buffalo Bills","team",["Teams","American Football","NFL","AFC","East"]),feed("college","Mount Union Football","ncaa-team",["NCAA","Division III","Football","Ohio Athletic Conference"]),feed("class","S1","classification",["Swimming","Para Swimming","Classes and Medley Indices","Freestyle and Backstroke"])];
it("starts at sports and merges competition selection with its team subtree",()=>{
 const tree=sportsFeedPickerTree(definitions,entities,"en-US");
 expect(tree.feeds.map(f=>f.id)).toEqual(["sports"]);
 expect(tree.children.map(n=>n.label)).toEqual(["Football","Swimming"]);
 const football=tree.children[0]!;
 const nfl=football.children.find(n=>n.label==="NFL")!;
 expect(nfl.feeds.map(f=>f.id)).toEqual(["nfl"]);
 expect(nfl.children[0]?.children[0]?.feeds[0]?.title).toBe("Buffalo Bills");
 expect(football.children.filter(n=>n.label==="NFL")).toHaveLength(1);
});
it("places NCAA division and conference after the canonical sport and preserves classification paths",()=>{
 const tree=sportsFeedPickerTree(definitions,entities,"en-GB");
 const football=tree.children.find(n=>n.label==="American Football")!;
 expect(football.children.find(n=>n.label==="NCAA")?.children[0]?.children[0]?.feeds[0]?.title).toBe("Mount Union Football");
 const swimming=tree.children.find(n=>n.label==="Swimming")!;
 expect(swimming.children[0]?.children[0]?.children[0]?.feeds[0]?.title).toBe("S1");
});
it("supports legacy catalogs and gives every feed a reachable node",()=>{
 const tree=sportsFeedPickerTree(definitions,[],"en-US");
 const ids:string[]=[];
 function collect(node:typeof tree){ids.push(...node.feeds.map(f=>f.id));node.children.forEach(collect);}
 collect(tree);
 expect(ids.sort()).toEqual(definitions.map(f=>f.id).sort());
});
it("keeps identity paths stable across locale changes and bounds search without losing the total",()=>{
 const us=sportsFeedPickerTree(definitions,entities,"en-US");
 const gb=sportsFeedPickerTree(definitions,entities,"en-GB");
 expect(us.children[0]?.id).toBe(gb.children[0]?.id);
 const matches=Array.from({length:90},(_,i)=>({...feed(String(i),`A Team ${i}`,"team"),searchAliases:["club"]}));
 expect(sportsPickerSearch(matches,"club").feeds).toHaveLength(50);
 expect(sportsPickerSearch(matches,"club").total).toBe(90);
});

it("uses reviewed competition relationships when display paths are absent",()=>{
 const player:SportsEntity={id:"player",name:"A Player",kind:"athlete",sportID:"football",competitionIDs:["missing","nfl"],aliases:[],active:true};
 const tree=sportsFeedPickerTree([...definitions,feed("player","A Player","athlete")],[...entities,player],"en-US");
 const nfl=tree.children.find(node=>node.label==="Football")?.children.find(node=>node.label==="NFL");
 expect(nfl?.feeds.some(item=>item.id==="player")).toBe(true);
});

it("orders numbered swimming classes naturally instead of lexically",()=>{
 const classes=["SB11","SB2","SB9","SB1"].map(name=>feed(name,name,"classification",["Swimming","Para Swimming","Classes and Medley Indices","Breaststroke"]));
 const classEntities=classes.map(item=>entity(item.id,item.title,"classification","swimming"));
 const tree=sportsFeedPickerTree(classes,[...entities,...classEntities],"en-US");
 expect(tree.children[0]?.children[0]?.children[0]?.children[0]?.feeds.map(item=>item.title)).toEqual(["SB1","SB2","SB9","SB11"]);
 const branches=classes.map(item=>({...item,groupPath:["Swimming",item.title]}));
 expect(sportsFeedPickerTree(branches,[...entities,...classEntities],"en-US").children[0]?.children.map(node=>node.label)).toEqual(["SB1","SB2","SB9","SB11"]);
});

it("keeps WGI disciplines and scholastic or independent classes separate from DCI",()=>{
 const arts=entity("arts","Indoor Marching Arts","sport");
 const drum=entity("drum","Drum Corps","sport");
 const wgi=entity("wgi","WGI","competition","arts");
 const disciplines=["Color Guard","Percussion","Winds"].map((name,index)=>entity(`discipline-${index}`,`WGI ${name}`,"competition","arts"));
 const groups=[entity("school","School Ensemble","team","arts"),entity("independent","Independent Ensemble","team","arts")];
 const feeds=[feed("arts",arts.name,"sport"),feed("drum",drum.name,"sport"),feed("wgi",wgi.name,"competition",["Indoor Marching Arts","WGI"]),...disciplines.map(item=>feed(item.id,item.name,"competition",["Indoor Marching Arts","WGI",item.name])),feed("school","School Ensemble","team",["Indoor Marching Arts","WGI","WGI Percussion","Marching","Scholastic","A Class"]),feed("independent","Independent Ensemble","team",["Indoor Marching Arts","WGI","WGI Percussion","Marching","Independent","World Class"])];
 const tree=sportsFeedPickerTree(feeds,[arts,drum,wgi,...disciplines,...groups]);
 const umbrella=tree.children.find(node=>node.label==="Indoor Marching Arts")?.children.find(node=>node.label==="WGI");
 expect(umbrella?.children.map(node=>node.label)).toEqual(["WGI Color Guard","WGI Percussion","WGI Winds"]);
 const marching=umbrella?.children.find(node=>node.label==="WGI Percussion")?.children.find(node=>node.label==="Marching");
 expect(marching?.children.map(node=>node.label)).toEqual(["Independent","Scholastic"]);
 expect(marching?.children.find(node=>node.label==="Scholastic")?.children[0]?.feeds[0]?.id).toBe("school");
 expect(tree.children.some(node=>node.label==="Drum Corps")).toBe(true);
});

it("honors a reviewed Marching Arts umbrella without replacing DCI or WGI sport identities",()=>{
 const umbrella=entity("marching","Marching Arts","sport");
 const drum=entity("drum","Drum Corps","sport");
 const indoor=entity("indoor","Indoor Marching Arts","sport");
 const ensembles=[entity("corps","Bluecoats","team","drum"),entity("guard","Example Guard","team","indoor"),entity("band","Example Band","team","marching")];
 const feeds=[feed("marching","Marching Arts","sport"),feed("drum","Drum Corps","sport",["Marching Arts","DCI"]),feed("indoor","Indoor Marching Arts","sport",["Marching Arts","WGI"]),feed("corps","Bluecoats","team",["Marching Arts","DCI","World Class"]),feed("guard","Example Guard","team",["Marching Arts","WGI","Color Guard"]),feed("band","Example Band","team",["Marching Arts","BOA","AAAA"])];
 const tree=sportsFeedPickerTree(feeds,[umbrella,drum,indoor,...ensembles]);
 expect(tree.children.map(node=>node.label)).toEqual(["Marching Arts"]);
 const root=tree.children[0]!;
 expect(root.feeds.map(item=>item.id)).toEqual(["marching"]);
 expect(root.children.map(node=>node.label)).toEqual(["BOA","DCI","WGI"]);
 expect(root.children.find(node=>node.label==="DCI")?.feeds[0]?.id).toBe("drum");
 expect(root.children.find(node=>node.label==="DCI")?.children[0]?.feeds[0]?.id).toBe("corps");
 expect(root.children.find(node=>node.label==="WGI")?.children[0]?.feeds[0]?.id).toBe("guard");
 expect(ensembles[0]?.sportID).toBe("drum");
});

it("nests reviewed MLB league divisions and preserves team feed identities",()=>{
 const baseball=entity("baseball","Baseball","sport");
 const mlb=entity("mlb","MLB","competition","baseball");
 const groups=["American League","National League"].flatMap(league=>["East","Central","West"].map(division=>({league,division,id:`team-${league}-${division}`})));
 const teamEntities=groups.map(group=>({...entity(group.id,`${group.league} ${group.division} Club`,"team","baseball"),competitionIDs:["mlb"]}));
 const feeds=[feed("baseball","Baseball","sport"),feed("mlb","MLB","competition",["Competitions","Baseball"]),...groups.map(group=>({...feed(group.id,`${group.league} ${group.division} Club`,"team",["Teams","Baseball","MLB",group.league,group.division]),id:`entity:${group.id}`}))];
 const tree=sportsFeedPickerTree(feeds,[baseball,mlb,...teamEntities],"en-US");
 const league=tree.children[0]?.children.find(node=>node.label==="MLB");
 expect(league?.feeds.map(item=>item.id)).toEqual(["mlb"]);
 expect(league?.children.map(node=>node.label)).toEqual(["American League","National League"]);
 for(const conference of league?.children ?? []) {
  expect(conference.children.map(node=>node.label)).toEqual(["Central","East","West"]);
  for(const division of conference.children) expect(division.feeds[0]?.id).toBe(`entity:team-${conference.label}-${division.label}`);
 }
});

it.each([
 {sport:"American Football",label:"Football",league:"NFL",conference:"NFC",division:"East"},
 {sport:"Ice Hockey",label:"Ice Hockey",league:"NHL",conference:"Eastern Conference",division:"Metropolitan"},
 {sport:"Football",label:"Soccer",league:"MLS",conference:"Eastern Conference",division:undefined},
])("preserves league access and reviewed nested team IDs in $league",({sport,label,league,conference,division})=>{
 const sportEntity=entity("sport-id",sport,"sport");
 const competition=entity("league-id",league,"competition","sport-id");
 const team={...entity("stable-team-id","Reviewed Team","team","sport-id"),competitionIDs:["league-id"]};
 const teamPath=["Teams",sport,league,conference,...division?[division]:[]];
 const feeds=[feed("sport-id",sport,"sport"),feed("league-id",league,"competition",["Competitions",sport]),{...feed("stable-team-id",team.name,"team",teamPath),id:"entity:stable-team-id"}];
 const tree=sportsFeedPickerTree(feeds,[sportEntity,competition,team],"en-US");
 const sportNode=tree.children.find(node=>node.label===label)!;
 const leagueNode=sportNode.children.find(node=>node.label===league)!;
 expect(leagueNode.feeds.map(item=>item.id)).toEqual(["league-id"]);
 const group=leagueNode.children.find(node=>node.label===conference)!;
 const leaf=division?group.children.find(node=>node.label===division)!:group;
 expect(leaf.feeds[0]?.id).toBe("entity:stable-team-id");
 expect(leaf.feeds[0]?.entityIDs).toEqual(["stable-team-id"]);
});

it("does not invent divisions for teams without a reviewed hierarchy",()=>{
 const baseball=entity("baseball","Baseball","sport");
 const mlb=entity("mlb","MLB","competition","baseball");
 const unknown={...entity("unknown-team","Unknown Team","team","baseball"),competitionIDs:["mlb"]};
 const tree=sportsFeedPickerTree([feed("mlb","MLB","competition"),feed("unknown-team",unknown.name,"team")],[baseball,mlb,unknown]);
 const league=tree.children[0]?.children[0];
 expect(league?.label).toBe("MLB");
 expect(league?.children).toEqual([]);
 expect(league?.feeds.some(item=>item.id==="unknown-team")).toBe(true);
});

it("organizes hockey disciplines under the reviewed umbrella without mixing competitions or identities",()=>{
 const hockey=entity("hockey-umbrella","Hockey","sport");
 const ice=entity("stable-ice-id","Ice Hockey","sport");
 const field=entity("field-hockey-id","Field Hockey","sport");
 const street=entity("street-hockey-id","Street Hockey","sport");
 const nhl=entity("nhl-id","NHL","competition",ice.id);
 const worldCup=entity("field-world-cup-id","FIH Hockey World Cup","competition",field.id);
 const flyers={...entity("stable-flyers-id","Philadelphia Flyers","team",ice.id),competitionIDs:[nhl.id]};
 const fieldTeam={...entity("field-team-id","Reviewed Field Hockey Team","team",field.id),competitionIDs:[worldCup.id]};
 const feeds=[feed(hockey.id,hockey.name,"sport"),feed(ice.id,ice.name,"sport",["Hockey","Ice Hockey"]),feed(field.id,field.name,"sport",["Hockey","Field Hockey"]),feed(street.id,street.name,"sport",["Hockey","Street Hockey"]),feed(nhl.id,nhl.name,"competition",["Hockey","Ice Hockey","NHL"]),feed(worldCup.id,worldCup.name,"competition",["Hockey","Field Hockey","FIH Hockey World Cup"]),feed(flyers.id,flyers.name,"team",["Teams","Hockey","Ice Hockey","NHL","Eastern Conference","Metropolitan"]),feed(fieldTeam.id,fieldTeam.name,"team",["Teams","Hockey","Field Hockey","FIH Hockey World Cup"])];
 const tree=sportsFeedPickerTree(feeds,[hockey,ice,field,street,nhl,worldCup,flyers,fieldTeam],"en-US");
 expect(tree.children.map(node=>node.label)).toEqual(["Hockey"]);
 const umbrella=tree.children[0]!;
 expect(umbrella.feeds.map(item=>item.id)).toEqual([hockey.id]);
 expect(umbrella.children.map(node=>node.label)).toEqual(["Field Hockey","Ice Hockey","Street Hockey"]);
 const iceNode=umbrella.children.find(node=>node.label==="Ice Hockey")!;
 const fieldNode=umbrella.children.find(node=>node.label==="Field Hockey")!;
 expect(iceNode.feeds[0]?.id).toBe("stable-ice-id");
 expect(fieldNode.feeds[0]?.id).toBe("field-hockey-id");
 expect(iceNode.children.map(node=>node.label)).toEqual(["NHL"]);
 expect(fieldNode.children.map(node=>node.label)).toEqual(["FIH Hockey World Cup"]);
 expect(iceNode.children[0]?.children[0]?.children[0]?.feeds[0]?.id).toBe("stable-flyers-id");
 expect(fieldNode.children[0]?.feeds.map(item=>item.id).sort()).toEqual(["field-team-id","field-world-cup-id"]);
 expect(flyers.sportID).toBe("stable-ice-id");
 expect(fieldTeam.sportID).toBe("field-hockey-id");
});
